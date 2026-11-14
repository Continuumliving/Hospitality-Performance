import { ImageResponse } from "next/og";

export const size = { width: 512, height: 512 };
export const contentType = "image/png";

const MARK = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 36 36"><circle cx="18.00" cy="5.00" r="2.6" fill="#C0835A"/><circle cx="25.64" cy="7.48" r="2.6" fill="#C0835A"/><circle cx="30.36" cy="13.98" r="2.6" fill="#C0835A"/><circle cx="30.36" cy="22.02" r="2.6" fill="#C0835A"/><circle cx="25.64" cy="28.52" r="2.6" fill="#C0835A"/><circle cx="18.00" cy="31.00" r="2.6" fill="#C0835A"/><circle cx="10.36" cy="28.52" r="2.6" fill="#C0835A"/><circle cx="5.64" cy="22.02" r="2.6" fill="#C0835A"/><circle cx="5.64" cy="13.98" r="2.6" fill="#C0835A"/><circle cx="10.36" cy="7.48" r="2.6" fill="#C0835A"/><circle cx="18" cy="18" r="4.4" fill="#C0835A"/></svg>`;

export default function Icon() {
  return new ImageResponse(
    (
      <div style={{ width: "100%", height: "100%", background: "#0F1A15", display: "flex", alignItems: "center", justifyContent: "center" }}>
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img width={378} height={378} src={`data:image/svg+xml;utf8,${encodeURIComponent(MARK)}`} alt="" />
      </div>
    ),
    { ...size },
  );
}
