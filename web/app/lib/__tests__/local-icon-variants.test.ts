import { existsSync, readdirSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { LOCAL_ICON_VARIANT_WIDTHS, sizedLocalIconSrc } from "@/app/lib/local-asset-icons"

const ICON_DIRS = ["asset-icons"]

describe("local icon WebP variants", () => {
  it("picks the smallest variant covering 2x the rendered size", () => {
    expect(sizedLocalIconSrc("/asset-icons/eth.png", 16)).toBe("/asset-icons/w64/eth.webp")
    expect(sizedLocalIconSrc("/asset-icons/eth.png", 32)).toBe("/asset-icons/w64/eth.webp")
    expect(sizedLocalIconSrc("/asset-icons/eth.png", 48)).toBe("/asset-icons/w96/eth.webp")
    expect(sizedLocalIconSrc("/asset-icons/eth.png", 64)).toBe("/asset-icons/w128/eth.webp")
    expect(sizedLocalIconSrc("https://cryptologos.cc/x.png", 16)).toBe("https://cryptologos.cc/x.png")
  })

  // Fails when an icon is added without running `node scripts/generate-icon-variants.mjs`.
  it.each(ICON_DIRS)("every /%s PNG has all generated variants", (dir) => {
    const root = join(process.cwd(), "public", dir)
    const missing = readdirSync(root)
      .filter((file) => file.endsWith(".png"))
      .flatMap((file) =>
        LOCAL_ICON_VARIANT_WIDTHS.map((width) => join(root, `w${width}`, file.replace(/\.png$/, ".webp"))),
      )
      .filter((path) => !existsSync(path))
    expect(missing).toEqual([])
  })
})
