-- ============================================================
-- Hospitality Performance app: complete database setup
-- Run once in a NEW, empty Supabase project (SQL Editor -> Run).
-- ============================================================


-- ---------- 0001_init.sql ----------
-- ============================================================
-- Continuum Living — initial schema
-- Run this in the Supabase SQL editor of a fresh project.
-- ============================================================

-- ENUMS ------------------------------------------------------
create type development_id as enum ('almina', 'alcantara');
create type intensity as enum ('high', 'low');
create type event_kind as enum ('dining', 'social', 'workshop', 'excursion', 'signature');
create type app_role as enum ('user', 'admin');

-- DEVELOPMENTS -----------------------------------------------
create table developments (
  id development_id primary key,
  name text not null,
  location text not null,
  series text not null default 'Series One',
  accent text not null default 'terracotta'
);

insert into developments (id, name, location, accent) values
  ('almina', 'Almina Residences', 'Estepona', 'terracotta'),
  ('alcantara', 'Alcántara del Mar', 'San Pedro de Alcántara', 'olive');

alter table developments enable row level security;
create policy "developments_read" on developments for select to authenticated using (true);

-- PROFILES ---------------------------------------------------
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  first_name text not null,
  last_name text not null default '',
  email text not null,
  development development_id not null,
  unit_number text not null,
  joined_at timestamptz not null default now(),
  role app_role not null default 'user'
);

create index profiles_development_idx on profiles (development);

alter table profiles enable row level security;

create policy "profiles_select_own" on profiles
  for select to authenticated using (id = auth.uid());

create policy "profiles_update_own" on profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid() and role = 'user');

create policy "profiles_insert_own" on profiles
  for insert to authenticated
  with check (id = auth.uid() and role = 'user');

-- Prevent self-elevation and residence change
create or replace function enforce_profiles_immutable()
returns trigger language plpgsql as $$
begin
  if new.role is distinct from old.role then
    raise exception 'role cannot be changed by the resident';
  end if;
  if new.development is distinct from old.development then
    raise exception 'development cannot be changed';
  end if;
  return new;
end;
$$;

create trigger profiles_immutable_fields
  before update on profiles
  for each row execute function enforce_profiles_immutable();

-- Auto-create profile on auth signup using user_metadata.
-- The insert is wrapped in an EXCEPTION block so a profile failure
-- never rolls back the auth.users insert. The client-side
-- ensureMyProfile() fallback will retry on first app load.
create or replace function handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin
    insert into profiles (id, first_name, last_name, email, development, unit_number)
    values (
      new.id,
      coalesce(new.raw_user_meta_data ->> 'first_name', ''),
      coalesce(new.raw_user_meta_data ->> 'last_name', ''),
      coalesce(new.email, ''),
      (coalesce(nullif(new.raw_user_meta_data ->> 'development', ''), 'almina'))::development_id,
      coalesce(new.raw_user_meta_data ->> 'unit_number', '')
    )
    on conflict (id) do nothing;
  exception when others then
    raise notice 'handle_new_auth_user: profile insert failed for %: % (%).',
      new.id, sqlerrm, sqlstate;
  end;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_auth_user();

-- CLASSES ----------------------------------------------------
create table classes (
  id uuid primary key default gen_random_uuid(),
  day smallint not null check (day between 0 and 6),
  "time" text not null,
  title text not null,
  venue text not null,
  intensity intensity not null,
  coach text not null,
  duration_min integer not null check (duration_min > 0),
  description text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create index classes_day_time_idx on classes (day, "time");

alter table classes enable row level security;

create policy "classes_read" on classes
  for select to authenticated using (true);

create policy "classes_admin_insert" on classes
  for insert to authenticated
  with check (exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin'));

create policy "classes_admin_update" on classes
  for update to authenticated
  using (exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin'))
  with check (exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin'));

create policy "classes_admin_delete" on classes
  for delete to authenticated
  using (exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin'));

-- BOOKINGS ---------------------------------------------------
create table bookings (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  class_id uuid not null references classes(id) on delete cascade,
  session_date date not null,
  created_at timestamptz not null default now(),
  unique (profile_id, class_id, session_date)
);

create index bookings_profile_date_idx on bookings (profile_id, session_date);

alter table bookings enable row level security;

create policy "bookings_select_own" on bookings
  for select to authenticated using (profile_id = auth.uid());

create policy "bookings_insert_own" on bookings
  for insert to authenticated with check (profile_id = auth.uid());

create policy "bookings_delete_own" on bookings
  for delete to authenticated using (profile_id = auth.uid());

-- SESSION HISTORY --------------------------------------------
create table session_history (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  class_id uuid references classes(id) on delete set null,
  title text not null,
  venue text not null,
  intensity intensity not null,
  session_date date not null,
  completed_at timestamptz not null default now()
);

create index session_history_profile_idx on session_history (profile_id, completed_at desc);

alter table session_history enable row level security;

create policy "session_history_select_own" on session_history
  for select to authenticated using (profile_id = auth.uid());

create policy "session_history_insert_own" on session_history
  for insert to authenticated with check (profile_id = auth.uid());

create policy "session_history_delete_own" on session_history
  for delete to authenticated using (profile_id = auth.uid());

-- On booking insert, also log to session_history
create or replace function log_booking_to_history()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  c record;
begin
  select title, venue, intensity into c from classes where id = new.class_id;
  if found then
    insert into session_history (profile_id, class_id, title, venue, intensity, session_date)
    values (new.profile_id, new.class_id, c.title, c.venue, c.intensity, new.session_date);
  end if;
  return new;
end;
$$;

drop trigger if exists bookings_to_history on bookings;
create trigger bookings_to_history
  after insert on bookings
  for each row execute function log_booking_to_history();

-- EVENTS -----------------------------------------------------
create table events (
  id uuid primary key default gen_random_uuid(),
  date date not null,
  "time" text not null,
  title text not null,
  venue text not null,
  host text not null,
  capacity integer not null check (capacity > 0),
  kind event_kind not null,
  description text not null,
  created_at timestamptz not null default now()
);

create index events_date_idx on events (date);

alter table events enable row level security;

create policy "events_read" on events
  for select to authenticated using (true);

create policy "events_admin_insert" on events
  for insert to authenticated
  with check (exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin'));

create policy "events_admin_update" on events
  for update to authenticated
  using (exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin'))
  with check (exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin'));

create policy "events_admin_delete" on events
  for delete to authenticated
  using (exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin'));

-- EVENT RSVPS ------------------------------------------------
create table event_rsvps (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  event_id uuid not null references events(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (profile_id, event_id)
);

create index event_rsvps_event_idx on event_rsvps (event_id);

alter table event_rsvps enable row level security;

create policy "event_rsvps_select_own" on event_rsvps
  for select to authenticated using (profile_id = auth.uid());

create policy "event_rsvps_insert_own" on event_rsvps
  for insert to authenticated with check (profile_id = auth.uid());

create policy "event_rsvps_delete_own" on event_rsvps
  for delete to authenticated using (profile_id = auth.uid());

-- Capacity trigger
create or replace function enforce_event_capacity()
returns trigger language plpgsql as $$
declare
  current_count int;
  max_cap int;
begin
  select capacity into max_cap from events where id = new.event_id;
  select count(*) into current_count from event_rsvps where event_id = new.event_id;
  if current_count >= max_cap then
    raise exception 'event at capacity';
  end if;
  return new;
end;
$$;

drop trigger if exists event_rsvps_capacity_check on event_rsvps;
create trigger event_rsvps_capacity_check
  before insert on event_rsvps
  for each row execute function enforce_event_capacity();

-- ============================================================
-- SEED DATA
-- ============================================================

-- Weekly programme (10 fixed classes)
insert into classes (day, "time", title, venue, intensity, coach, duration_min, description) values
  (1, '07:00', 'HYROX training', 'Sports Centre', 'high', 'Tomash', 60,
   'Race-specific conditioning across eight movement stations. Strength endurance meets structured intervals. Intended for residents comfortable under load.'),
  (1, '19:00', 'Mobility & stretching', 'Spa', 'low', 'Elena', 45,
   'Slow, considered work through the hips, thoracic spine and posterior chain. Ideal after travel or a long day of meetings.'),
  (2, '07:30', 'Yoga & meditation', 'Wellness Studio', 'low', 'Elena', 60,
   'A Vinyasa flow grounded in breath, followed by a ten-minute guided meditation. All levels held in the same room.'),
  (2, '18:30', 'Functional strength', 'Gym', 'high', 'Tomash', 60,
   'Full-body strength circuit with kettlebells, dumbbells and bodyweight. Progressive, programmed, built for longevity.'),
  (3, '06:30', 'Social run + intervals', 'Coastal Route', 'high', 'Marc', 60,
   'Easy 5km along the paseo marítimo with structured intervals in the final kilometre. Espresso at the clubhouse afterwards.'),
  (3, '19:00', 'Sound bath & restore', 'Wellness Studio', 'low', 'Visiting', 60,
   'A supine session with singing bowls and gong. The lights go low, the day goes quiet, the nervous system follows.'),
  (4, '07:30', 'Pilates core flow', 'Wellness Studio', 'low', 'Elena', 50,
   'Mat-based Pilates emphasising breath, alignment and deep core. Small adjustments make the difference.'),
  (4, '18:30', 'Sprint & agility', 'Indoor Football Pitch', 'high', 'Marc', 45,
   'Short accelerations, lateral work, and reactive drills. A sharpening session, not a grind.'),
  (5, '07:00', 'Boxing & conditioning', 'Sports Centre', 'high', 'Tomash', 60,
   'Pad work, combinations and conditioning rounds. No sparring. Technical precision over intensity.'),
  (5, '19:00', 'Breathwork & recovery', 'Wellness Studio', 'low', 'Elena', 45,
   'Box breathing, extended exhale, and a guided body scan. The quietest hour of the week.');

-- Six seed events
insert into events (date, "time", title, venue, host, capacity, kind, description) values
  ('2026-04-25', '19:30', 'Resident dinner', 'Private dining · Almina', 'Hosted by the house', 24, 'dining',
   'A considered five-course tasting prepared by our visiting chef. Natural wine pairing available. Seating is communal, at a single long table.'),
  ('2026-04-28', '18:00', 'Pool club social evening', 'Pool Club · Alcántara del Mar', 'Hosted by Continuum', 40, 'social',
   'Aperitivo hour at sunset. Cold plates, signature negronis, a live vinyl set from a guest selector. Dress: smart, coastal.'),
  ('2026-05-02', '10:00', 'Wellness workshop · Sleep', 'Wellness Studio · Almina', 'With Dr. Corán', 20, 'workshop',
   'A two-hour seminar on the science of sleep and its effect on performance. Includes a take-home protocol and breath practice.'),
  ('2026-05-08', '07:00', 'Hiking excursion · Sierra Blanca', 'Meet at Alcántara del Mar', 'Led by Marc', 16, 'excursion',
   'A moderate four-hour route into the mountains above Marbella. Breakfast at altitude, return to the residence before noon.'),
  ('2026-05-11', '11:00', 'Holistic brunch', 'Rooftop · Almina', 'Hosted by Continuum', 30, 'dining',
   'A considered late morning — cold-pressed juices, slow grains, and a brief conversation on seasonal eating.'),
  ('2026-05-17', '17:00', 'Signature summer opening', 'All venues · Alcántara del Mar', 'The Continuum season', 80, 'signature',
   'Our seasonal programme launch. Drinks, a short address from the founder, and an introduction to the summer calendar.');

-- ============================================================
-- HOW TO GRANT ADMIN
-- ============================================================
-- After creating a user via the Continuum signup, run:
--   update profiles set role = 'admin' where email = 'you@example.com';
-- This bypasses the self-elevation guard because it runs as the
-- service role from the SQL editor.


-- ---------- 0002_signup_hardening.sql ----------
-- ============================================================
-- 0002_signup_hardening.sql
-- Run AFTER 0001_init.sql in a fresh project, or standalone to
-- patch an existing deploy where signup was failing silently.
-- ============================================================
--
-- Background: the original handle_new_auth_user trigger ran as
-- AFTER INSERT on auth.users. Any exception inside it (missing
-- metadata, enum cast failure, RLS/permission hiccup) rolls back
-- the whole transaction, which means NO auth.users row is ever
-- persisted — Supabase returns a 500 but the Authentication >
-- Users list stays empty. This patch:
--
-- 1. Wraps the profile insert in a BEGIN/EXCEPTION block so a
--    profile failure never aborts the auth user creation.
-- 2. Uses `nullif(…, '')` before casting to the development_id
--    enum, so an empty-string metadata value falls back cleanly.
-- 3. Logs any trigger error as a Postgres NOTICE for debugging.
--
-- Combined with the client-side ensureMyProfile() fallback, a
-- missing profile row self-heals on the user's next app load.
-- ============================================================

create or replace function handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    insert into profiles (id, first_name, last_name, email, development, unit_number)
    values (
      new.id,
      coalesce(new.raw_user_meta_data ->> 'first_name', ''),
      coalesce(new.raw_user_meta_data ->> 'last_name', ''),
      coalesce(new.email, ''),
      (coalesce(nullif(new.raw_user_meta_data ->> 'development', ''), 'almina'))::development_id,
      coalesce(new.raw_user_meta_data ->> 'unit_number', '')
    )
    on conflict (id) do nothing;
  exception when others then
    -- Never abort the auth user creation. The client-side
    -- ensureMyProfile() will insert the profile on first app load.
    raise notice 'handle_new_auth_user: profile insert failed for %: % (%).',
      new.id, sqlerrm, sqlstate;
  end;
  return new;
end;
$$;

-- Make sure the trigger is still wired up.
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_auth_user();


-- ---------- 0005_admin_access.sql ----------
-- ============================================================
-- 0005_admin_access.sql
--   * is_admin() helper (SECURITY DEFINER, search_path locked) so
--     admin policies can check the role without recursing into the
--     profiles table's own RLS.
--   * admin SELECT policies on profiles / bookings / event_rsvps
--     so the /admin dashboard can read every resident's data.
--     Non-admins remain restricted to their own rows.
--   * classes.capacity column with a sensible default so the
--     dashboard can show "X / capacity · Y spots left" per class.
-- Idempotent: safe to run multiple times.
-- ============================================================

-- helper -------------------------------------------------------
create or replace function is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and role = 'admin'
  );
$$;

revoke all on function is_admin() from public;
grant execute on function is_admin() to authenticated;

-- profiles -----------------------------------------------------
drop policy if exists "profiles_admin_select" on profiles;
create policy "profiles_admin_select" on profiles
  for select to authenticated
  using (is_admin());

-- bookings -----------------------------------------------------
drop policy if exists "bookings_admin_select" on bookings;
create policy "bookings_admin_select" on bookings
  for select to authenticated
  using (is_admin());

-- event_rsvps --------------------------------------------------
drop policy if exists "event_rsvps_admin_select" on event_rsvps;
create policy "event_rsvps_admin_select" on event_rsvps
  for select to authenticated
  using (is_admin());

-- classes.capacity --------------------------------------------
alter table classes
  add column if not exists capacity integer not null default 20
  check (capacity > 0);


-- ---------- 0006 (structure) ----------
-- ============================================================
-- 0006_owners_app.sql
-- Continuum Owners App (v2 design).
--   * classes.image / classes.category and events.image columns
--   * class_booking_counts() and event_rsvp_counts(): aggregate
--     counts residents may see ("4 of 6 places") without exposing
--     anyone else's bookings (SECURITY DEFINER, counts only)
--   * replaces the old pilot programme with the neutral Owners App
--     programme and upcoming events. NOTE: this removes existing
--     classes/events, and with them any test bookings and RSVPs.
-- Safe to run more than once.
-- ============================================================

alter table classes add column if not exists image text;
alter table classes add column if not exists category text not null default 'Push';
alter table events  add column if not exists image text;

-- counts ------------------------------------------------------
create or replace function class_booking_counts(p_from date, p_to date)
returns table (class_id uuid, session_date date, n integer)
language sql
security definer
set search_path = public
stable
as $$
  select b.class_id, b.session_date, count(*)::int
    from bookings b
   where b.session_date between p_from and p_to
   group by b.class_id, b.session_date;
$$;

revoke all on function class_booking_counts(date, date) from public;
grant execute on function class_booking_counts(date, date) to authenticated;

create or replace function event_rsvp_counts()
returns table (event_id uuid, n integer)
language sql
security definer
set search_path = public
stable
as $$
  select r.event_id, count(*)::int
    from event_rsvps r
   group by r.event_id;
$$;

revoke all on function event_rsvp_counts() from public;
grant execute on function event_rsvp_counts() to authenticated;

-- capacity guard for class bookings -------------------------
create or replace function enforce_class_capacity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cap int;
  taken int;
begin
  select capacity into cap from classes where id = new.class_id;
  select count(*) into taken from bookings
   where class_id = new.class_id and session_date = new.session_date;
  if cap is not null and taken >= cap then
    raise exception 'class at capacity';
  end if;
  return new;
end;
$$;

drop trigger if exists bookings_capacity_check on bookings;
create trigger bookings_capacity_check
  before insert on bookings
  for each row execute function enforce_class_capacity();



-- ---------- HP programme ----------
-- day: 0 = Sunday … 6 = Saturday
delete from classes;
insert into classes (day, "time", title, venue, intensity, coach, duration_min, capacity, category, image, description) values
  (1, '07:30', 'Performance Training',        'On site',  'high', 'Tomash', 50, 10, 'Push',    'gym',      'Strength and conditioning for people who are on their feet all day.'),
  (2, '15:00', 'Pilates & Core Stability',    'On site',  'low',  'Tomash', 45, 10, 'Restore', 'pilates',  'Posture, core and back health. Ideal between shifts.'),
  (3, '07:00', 'Social Endurance Run',        'Outdoor',  'high', 'Tomash', 50, 10, 'Explore', 'hike',     'An easy group run at conversation pace. Every level welcome.'),
  (4, '15:00', 'HYROX & Functional',          'On site',  'high', 'Tomash', 50, 10, 'Push',    'kb',       'Functional stations and short intervals. Scaled to your level.'),
  (5, '07:30', 'Boxing & Conditioning',       'On site',  'high', 'Tomash', 50, 10, 'Push',    'boxing',   'Pads, bag work and conditioning rounds. No experience needed.'),
  (5, '15:00', 'Recovery & Mobility Flow',    'On site',  'low',  'Tomash', 45, 12, 'Restore', 'yoga',     'Slow mobility and breathing to recover from long shifts.');

delete from events;
insert into events (date, "time", title, venue, host, capacity, kind, image, description) values
  ('2026-12-10', '10:00', 'Wellness Workshop: Sleep & Shift Work', 'On site', 'Hosted by Tomash', 25, 'workshop', 'tub',
   'Practical tools for better sleep and energy when your hours change every week.'),
  ('2027-01-21', '10:00', 'Holistic Class & Brunch', 'On site', 'Hosted by Hospitality Performance', 20, 'dining', 'dinner',
   'A gentle movement class followed by a healthy brunch together.'),
  ('2027-02-18', '09:00', 'Team Hike', 'Meeting point shared before', 'Led by Tomash', 20, 'excursion', 'hike',
   'A morning hike with the whole team, finishing with coffee.'),
  ('2027-03-18', '16:00', 'Team Sports Challenge', 'Outdoor', 'Hosted by Hospitality Performance', 30, 'social', 'gym',
   'A friendly competition across departments. Teams are mixed on the day.');

update developments set name = 'Your team', location = '';


-- ---------- 0007_coach_messages.sql ----------
-- ============================================================
-- 0007_coach_messages.sql
-- Private 1:1 messaging between each resident and the coach.
--   * one thread per resident (resident_id); the coach is any admin
--   * residents read/write only their own thread
--   * admins read every thread and reply in any thread
--   * read_at marks a message as read by the other side
-- Safe to run more than once.
-- ============================================================

create table if not exists coach_messages (
  id           uuid primary key default gen_random_uuid(),
  resident_id  uuid not null references profiles(id) on delete cascade,
  sender_id    uuid not null references profiles(id) on delete cascade,
  body         text not null check (char_length(body) between 1 and 2000),
  created_at   timestamptz not null default now(),
  read_at      timestamptz
);

create index if not exists coach_messages_thread_idx
  on coach_messages (resident_id, created_at);

alter table coach_messages enable row level security;

drop policy if exists "coach_messages_select" on coach_messages;
create policy "coach_messages_select" on coach_messages
  for select to authenticated
  using (resident_id = auth.uid() or is_admin());

drop policy if exists "coach_messages_insert" on coach_messages;
create policy "coach_messages_insert" on coach_messages
  for insert to authenticated
  with check (
    sender_id = auth.uid()
    and (resident_id = auth.uid() or is_admin())
  );

-- marking as read: only via the function below (no direct updates)
drop policy if exists "coach_messages_update" on coach_messages;

create or replace function mark_thread_read(p_resident uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update coach_messages
     set read_at = now()
   where resident_id = p_resident
     and read_at is null
     and sender_id <> auth.uid()
     and (p_resident = auth.uid() or is_admin());
$$;

revoke all on function mark_thread_read(uuid) from public;
grant execute on function mark_thread_read(uuid) to authenticated;


-- ---------- 0008_push_notifications.sql ----------
-- ============================================================
-- 0008_push_notifications.sql
-- Web push subscriptions (one row per device) and a helper that
-- returns who should be notified about a message in a thread:
--   * resident writes  -> every admin (coach) device
--   * coach writes     -> that resident's devices
-- Safe to run more than once.
-- ============================================================

create table if not exists push_subscriptions (
  id          uuid primary key default gen_random_uuid(),
  profile_id  uuid not null references profiles(id) on delete cascade,
  endpoint    text not null unique,
  p256dh      text not null,
  auth        text not null,
  created_at  timestamptz not null default now()
);

alter table push_subscriptions enable row level security;

drop policy if exists "push_own_select" on push_subscriptions;
create policy "push_own_select" on push_subscriptions
  for select to authenticated using (profile_id = auth.uid());

drop policy if exists "push_own_insert" on push_subscriptions;
create policy "push_own_insert" on push_subscriptions
  for insert to authenticated with check (profile_id = auth.uid());

drop policy if exists "push_own_update" on push_subscriptions;
create policy "push_own_update" on push_subscriptions
  for update to authenticated using (profile_id = auth.uid()) with check (profile_id = auth.uid());

drop policy if exists "push_own_delete" on push_subscriptions;
create policy "push_own_delete" on push_subscriptions
  for delete to authenticated using (profile_id = auth.uid());

create or replace function push_targets_for_thread(p_resident uuid)
returns table (endpoint text, p256dh text, auth text)
language sql
security definer
set search_path = public
stable
as $$
  select s.endpoint, s.p256dh, s.auth
    from push_subscriptions s
    join profiles p on p.id = s.profile_id
   where (
           -- resident wrote: notify coaches
           auth.uid() = p_resident and p.role = 'admin' and s.profile_id <> auth.uid()
         )
      or (
           -- coach wrote: notify the resident
           is_admin() and auth.uid() <> p_resident and s.profile_id = p_resident
         );
$$;

revoke all on function push_targets_for_thread(uuid) from public;
grant execute on function push_targets_for_thread(uuid) to authenticated;

-- lets the server drop a dead device endpoint it was told about
create or replace function drop_push_endpoint(p_endpoint text)
returns void
language sql
security definer
set search_path = public
as $$
  delete from push_subscriptions where endpoint = p_endpoint;
$$;

revoke all on function drop_push_endpoint(text) from public;
grant execute on function drop_push_endpoint(text) to authenticated;

-- unread counter for the tab bar badge
create or replace function my_unread_count()
returns integer
language sql
security definer
set search_path = public
stable
as $$
  select case
    when is_admin() then (
      select count(*)::int from coach_messages
       where read_at is null and sender_id = resident_id
    )
    else (
      select count(*)::int from coach_messages
       where resident_id = auth.uid() and read_at is null and sender_id <> auth.uid()
    )
  end;
$$;

revoke all on function my_unread_count() from public;
grant execute on function my_unread_count() to authenticated;


-- ---------- 0009_health_brief.sql ----------
-- ============================================================
-- 0009_health_brief.sql
-- Personal Health Brief, written by the coach.
--   * health_profiles : one row per resident (consent, goal, intake,
--                       next review)
--   * health_metrics  : measurements over time (session heart rate, weight, body fat)
--   * weekly_briefs   : the coach's weekly note + next week's focus
-- Health data is special-category data (GDPR art. 9): the coach can
-- only record metrics after the resident has given explicit consent
-- in the app, and the resident can withdraw it (which deletes them).
-- Residents read only their own data; admins (coach) read/write all.
-- Safe to run more than once.
-- ============================================================

create table if not exists health_profiles (
  resident_id     uuid primary key references profiles(id) on delete cascade,
  consent_at      timestamptz,
  goal            text check (char_length(goal) <= 300),
  intake_date     date,
  next_review     date,
  coach_notes     text check (char_length(coach_notes) <= 4000),
  updated_at      timestamptz not null default now()
);

create table if not exists health_metrics (
  id           uuid primary key default gen_random_uuid(),
  resident_id  uuid not null references profiles(id) on delete cascade,
  kind         text not null,
  value        numeric not null check (value > 0 and value < 1000),
  measured_on  date not null default current_date,
  note         text check (char_length(note) <= 300),
  created_at   timestamptz not null default now()
);
-- what the coach can actually measure: heart rate during sessions
-- (average / maximum, from the heart-rate monitors) and body composition
alter table health_metrics drop constraint if exists health_metrics_kind_check;
alter table health_metrics add constraint health_metrics_kind_check
  check (kind in ('avg_hr','max_hr','weight','body_fat'));

create index if not exists health_metrics_resident_idx on health_metrics (resident_id, kind, measured_on);

create table if not exists weekly_briefs (
  id           uuid primary key default gen_random_uuid(),
  resident_id  uuid not null references profiles(id) on delete cascade,
  week_start   date not null,
  note         text not null default '' check (char_length(note) <= 4000),
  focus        text not null default '' check (char_length(focus) <= 1000),
  published    boolean not null default false,
  published_at timestamptz,
  updated_at   timestamptz not null default now(),
  unique (resident_id, week_start)
);

alter table health_profiles enable row level security;
alter table health_metrics  enable row level security;
alter table weekly_briefs   enable row level security;

-- health_profiles: only the coach reads the table directly (it holds
-- private coach notes); residents use my_health_profile() below
drop policy if exists "hp_select" on health_profiles;
create policy "hp_select" on health_profiles for select to authenticated
  using (is_admin());
drop policy if exists "hp_admin_write" on health_profiles;
create policy "hp_admin_write" on health_profiles for all to authenticated
  using (is_admin()) with check (is_admin());

-- metrics: only with consent
drop policy if exists "hm_select" on health_metrics;
create policy "hm_select" on health_metrics for select to authenticated
  using (resident_id = auth.uid() or is_admin());
drop policy if exists "hm_admin_insert" on health_metrics;
create policy "hm_admin_insert" on health_metrics for insert to authenticated
  with check (
    is_admin()
    and exists (select 1 from health_profiles h where h.resident_id = health_metrics.resident_id and h.consent_at is not null)
  );
drop policy if exists "hm_admin_delete" on health_metrics;
create policy "hm_admin_delete" on health_metrics for delete to authenticated
  using (is_admin());

-- briefs: residents see only published ones
drop policy if exists "wb_select" on weekly_briefs;
create policy "wb_select" on weekly_briefs for select to authenticated
  using ((resident_id = auth.uid() and published) or is_admin());
drop policy if exists "wb_admin_write" on weekly_briefs;
create policy "wb_admin_write" on weekly_briefs for all to authenticated
  using (is_admin()) with check (is_admin());

-- consent (resident acts on own row only) -----------------------
create or replace function give_health_consent()
returns void language sql security definer set search_path = public as $$
  insert into health_profiles (resident_id, consent_at)
  values (auth.uid(), now())
  on conflict (resident_id) do update set consent_at = coalesce(health_profiles.consent_at, now()), updated_at = now();
$$;
revoke all on function give_health_consent() from public;
grant execute on function give_health_consent() to authenticated;

create or replace function withdraw_health_consent()
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from health_metrics where resident_id = auth.uid();
  update health_profiles set consent_at = null, updated_at = now() where resident_id = auth.uid();
end;
$$;
revoke all on function withdraw_health_consent() from public;
grant execute on function withdraw_health_consent() to authenticated;

-- residents read their own profile without the coach's private notes
drop view if exists my_health_profile;
create or replace function my_health_profile()
returns table (consent_at timestamptz, goal text, intake_date date, next_review date)
language sql security definer set search_path = public stable as $$
  select consent_at, goal, intake_date, next_review
    from health_profiles where resident_id = auth.uid();
$$;
revoke all on function my_health_profile() from public;
grant execute on function my_health_profile() to authenticated;


-- ---------- 0010_attendance.sql ----------
-- ============================================================
-- 0010_attendance.sql
-- The coach marks who actually attended a booked session.
--   attended = true   -> attended
--   attended = false  -> no-show
--   attended = null   -> not marked yet
-- Only admins can set it (residents keep insert/delete on own rows).
-- Safe to run more than once.
-- ============================================================
alter table bookings add column if not exists attended boolean;
alter table bookings add column if not exists attended_at timestamptz;

drop policy if exists "bookings_admin_update" on bookings;
create policy "bookings_admin_update" on bookings
  for update to authenticated
  using (is_admin()) with check (is_admin());
