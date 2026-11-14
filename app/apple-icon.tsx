import { ImageResponse } from "next/og";

export const size = { width: 180, height: 180 };
export const contentType = "image/png";

export default function AppleIcon() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          background: "#0F1A15",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          color: "#C0835A",
          fontStyle: "italic",
          fontFamily: "Georgia, serif",
          fontSize: 74,
        }}
      >
        HP
      </div>
    ),
    { ...size },
  );
}
