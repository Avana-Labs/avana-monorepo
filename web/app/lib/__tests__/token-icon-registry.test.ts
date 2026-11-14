import { describe, expect, it } from "vitest"
import { allTokenIconMetas } from "@/app/lib/token-icons"
import { LOCAL_ASSET_ICON_FALLBACK } from "@/app/lib/local-asset-icons"

/**
 * The latent "must be in both registries" gotcha: every TOKEN_MAP entry hard-codes
 * `iconUrl: getLocalAssetIcon(symbol)` at module load. If that symbol is missing from
 * LOCAL_ASSET_ICON_SLUGS, getLocalAssetIcon returns the neutral placeholder — which is
 * truthy, so TokenIcon renders a gray placeholder forever instead of a colored letter.
 * This guardrail fails the build if any curated entry falls through, so a new TOKEN_MAP
 * token can't silently ship without its /asset-icons slug.
 */
describe("token icon registry guardrail", () => {
  it("no TOKEN_MAP entry with an iconUrl resolves to the neutral placeholder", () => {
    const brokenSymbols = allTokenIconMetas()
      .filter((meta) => meta.iconUrl !== undefined && meta.iconUrl === LOCAL_ASSET_ICON_FALLBACK)
      .map((meta) => meta.symbol)
    expect(brokenSymbols).toEqual([])
  })

  it("every registered icon points at an /asset-icons png", () => {
    for (const meta of allTokenIconMetas()) {
      if (meta.iconUrl === undefined) continue // intentional letter-fallback entry (e.g. MOG)
      expect(meta.iconUrl).toMatch(/^\/asset-icons\/[a-z0-9-]+\.png$/)
    }
  })
})
