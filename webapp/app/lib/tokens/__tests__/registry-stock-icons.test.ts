import { existsSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { getLocalAssetIcon, LOCAL_ICON_VARIANT_WIDTHS, sizedLocalIconSrc } from "@/app/lib/local-asset-icons"
import { registryDisplaySymbol } from "@/app/lib/tokens/registry"

const PUBLIC = join(__dirname, "../../../../public")

// The tokenized stocks the Hub files list (contracts/script/deploy/hubs/*/test-world*.json).
const LISTED_STOCKS = ["AMZNc", "GOOGLc", "METAc", "NVDAc", "SNDKc", "SPCXc"]

describe("stock token icons", () => {
  it.each(LISTED_STOCKS)("%s has its own icon and every sized variant on disk", (symbol) => {
    const icon = getLocalAssetIcon(symbol)
    expect(icon).toMatch(/^\/stock-Icons\/[a-z-]+\.png$/)
    expect(existsSync(join(PUBLIC, icon))).toBe(true)
    for (const width of LOCAL_ICON_VARIANT_WIDTHS) {
      expect(existsSync(join(PUBLIC, sizedLocalIconSrc(icon, width / 2)))).toBe(true)
    }
  })

  it("keeps the Aerodrome ticker casing", () => {
    expect(registryDisplaySymbol("GOOGLC")).toBe("GOOGLc")
    expect(getLocalAssetIcon("GOOGLc")).toBe("/stock-Icons/google.png")
  })
})
