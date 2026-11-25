import { readFile } from "node:fs/promises"
import { join } from "node:path"
import { ImageResponse } from "next/og"

// Branded share card used for og:image + (via summary_large_image) the X/Twitter card.
// Served from the app's own origin so the share preview works on any deploy domain.
// Runs on the default Node.js runtime so the card is statically generated at build
// time — pinning the edge runtime would disable static generation for this route.
export const alt = "Avana: a new Aave v4 lending market built for AMM markets"
export const size = { width: 1200, height: 630 }
export const contentType = "image/png"

const BRAND = "#01AACF"
const INK = "#F4F6F8"
const MUTED = "#8B93A7"
const VOID = "#050608"

function toPngDataUrl(bytes: Buffer) {
  return `data:image/png;base64,${bytes.toString("base64")}`
}

export default async function OpengraphImage() {
  // Keep each path a literal inside join(): output file tracing resolves those statically.
  // A variable path made the tracer include the whole working directory (1,051 repo files,
  // README and tests included), and because Next imports this metadata module into every
  // page, each page function shipped that copy of the repo.
  const [wordmark, icon] = await Promise.all([
    readFile(join(process.cwd(), "public/avana-wordmark-440.png")).then(toPngDataUrl),
    readFile(join(process.cwd(), "public/avana-icon.png")).then(toPngDataUrl),
  ])

  return new ImageResponse(
    <div
      style={{
        width: "100%",
        height: "100%",
        display: "flex",
        position: "relative",
        overflow: "hidden",
        background: VOID,
        color: INK,
        fontFamily: "sans-serif",
      }}
    >
      {/* Soft brand wash — keeps the card from reading as flat black. */}
      <div
        style={{
          position: "absolute",
          inset: 0,
          display: "flex",
          background:
            "radial-gradient(ellipse 70% 80% at 100% 20%, rgba(1,170,207,0.22) 0%, transparent 55%), radial-gradient(ellipse 50% 60% at 0% 100%, rgba(1,170,207,0.10) 0%, transparent 50%)",
        }}
      />

      {/* Real mark as a large atmospheric anchor (matches header BrandIcon). */}
      <img
        src={icon}
        width={620}
        height={682}
        alt=""
        style={{
          position: "absolute",
          right: -120,
          top: -40,
          opacity: 0.18,
          objectFit: "contain",
        }}
      />

      <div
        style={{
          position: "relative",
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          width: "100%",
          height: "100%",
          padding: "72px 80px",
        }}
      >
        {/* Real wordmark — same asset as the product header. */}
        <img src={wordmark} width={200} height={78} alt="Avana" style={{ objectFit: "contain" }} />

        <div style={{ display: "flex", flexDirection: "column", gap: 22, maxWidth: 760 }}>
          <div
            style={{
              display: "flex",
              flexDirection: "column",
              fontSize: 64,
              fontWeight: 400,
              lineHeight: 1.1,
              letterSpacing: "-0.03em",
              color: INK,
            }}
          >
            <div>Borrow Against</div>
            <div>Liquidity Positions</div>
          </div>
          <div style={{ fontSize: 26, fontWeight: 400, lineHeight: 1.35, color: MUTED, maxWidth: 680 }}>
            Borrow on Aave using your AMM liquidity position as collateral while your LP continues to earn trading fees.
          </div>
        </div>

        <div style={{ fontSize: 28, fontWeight: 400, color: BRAND, letterSpacing: "-0.01em" }}>app.avana.cc</div>
      </div>
    </div>,
    { ...size },
  )
}
