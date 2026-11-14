import { describe, expect, it } from "vitest"
import {
  formatRewardsApyLabel,
  injectAvailableUsdQuickStat,
  injectSiloedMarketQuickStats,
  overlayHeroIdentity,
} from "@/app/lib/detail-page/siloed-market-overlay"

describe("siloed-market-overlay", () => {
  it("overlays hero identity from siloed market when present", () => {
    const hero = overlayHeroIdentity(
      { name: "Catalog Name", venue: "Catalog Venue", explorerUrl: "https://example.com/old", feeTier: "0.3%" },
      {
        name: "Convex Name",
        symbol: "CVX",
        venueLabel: "Convex Venue",
        explorerUrl: "https://example.com/new",
        feeTier: "0.05%",
      },
    )
    expect(hero.name).toBe("Convex Name")
    expect(hero.venue).toBe("Convex Venue")
    expect(hero.explorerUrl).toBe("https://example.com/new")
    expect(hero.feeTier).toBe("0.05%")
  })

  it("keeps catalog hero when siloed market is missing", () => {
    const hero = { name: "Catalog", symbol: "CAT" }
    expect(overlayHeroIdentity(hero, null)).toEqual(hero)
  })

  it("injects reserve factor and rewards APY into quick stats", () => {
    const stats = injectSiloedMarketQuickStats(
      [
        { id: "rewardsApy", value: "No rewards" },
        { id: "reserveFactor", value: "10%" },
        { id: "supplyApy", value: "3.00%" },
      ],
      { reserveFactorPct: 12, rewardsApyPct: 1.25 },
    )
    expect(stats.find((s) => s.id === "reserveFactor")?.value).toBe("12%")
    expect(stats.find((s) => s.id === "rewardsApy")?.value).toBe("1.25%")
    expect(stats.find((s) => s.id === "supplyApy")?.value).toBe("3.00%")
  })

  it("formats zero rewards as No rewards", () => {
    expect(formatRewardsApyLabel(0)).toBe("No rewards")
    expect(formatRewardsApyLabel(undefined)).toBe("No rewards")
  })

  it("injects available liquidity from snapshot USD", () => {
    const stats = injectAvailableUsdQuickStat(
      [
        { id: "available", value: "$1.00" },
        { id: "price", value: "$1.00" },
      ],
      1_250_000,
      (n) => `$${n}`,
    )
    expect(stats.find((s) => s.id === "available")?.value).toBe("$1250000")
    expect(stats.find((s) => s.id === "price")?.value).toBe("$1.00")
  })
})
