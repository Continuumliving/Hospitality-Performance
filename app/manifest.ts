import type { MetadataRoute } from "next";

export default function manifest(): MetadataRoute.Manifest {
  return {
    name: "Hospitality Performance · Team",
    short_name: "HP",
    description:
      "Training, team events, your coach and your personal health brief: the wellbeing programme for your team.",
    display: "standalone",
    orientation: "portrait",
    start_url: "/today",
    scope: "/",
    background_color: "#f6f2ea",
    theme_color: "#f6f2ea",
    icons: [
      { src: "/icon", sizes: "any", type: "image/svg+xml" },
      { src: "/apple-icon", sizes: "180x180", type: "image/png" },
    ],
  };
}
