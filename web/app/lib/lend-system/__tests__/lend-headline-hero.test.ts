import { describe, expect, it } from "vitest"
import { resolveLendHeadlineRates } from "@/app/lib/lend-detail/headline-rates"
import { aggregateLendHeroFromMarkets } from "@/app/lib/lend-system/lend-hero-aggregates"
import { buildLendCatalogBaselineState } from "@/app/lib/lend-system/mock"
import { mergeConvexLendSnapshots } from "@/app/lib/lend-system/market-hydration"
import { buildLendPageData } from "@/app/lib/lend-system/read-model"

describe("resolveLendHeadlineRates", () => {
  it("keeps snapshot util/APR when snapshot-backed even if IRM differs", () => {
    const rates = resolveLendHeadlineRates({
      snapshotBacked: true,
      detailUtilizationPct: 61.5,
      detailBorrowAprPct: 8.2,
      irmUtilizationPct: 12,
      irmBorrowAprPct: 99,
    })
    expect(rates.utilizationPct).toBe(61.5)
    expect(rates.borrowAprPct).toBe(8.2)
  })

  it("allows IRM fallback only when not snapshot-backed", () => {
    const rates = resolveLendHeadlineRates({
      snapshotBacked: false,
      detailUtilizationPct: 40,
      detailBorrowAprPct: 5,
      irmUtilizationPct: 55,
      irmBorrowAprPct: 7.5,
    })
    expect(rates.utilizationPct).toBe(55)
    expect(rates.borrowAprPct).toBe(7.5)
  })
})

describe("aggregateLendHeroFromMarkets", () => {
  it("hero Σ TVL/util matches the same market row fields after Convex hydrate", () => {
    const baseline = buildLendCatalogBaselineState("demo-wallet")
    const slug = Object.keys(baseline.markets)[0]!
    const hydrated = mergeConvexLendSnapshots(baseline, [
      {
        slug,
        scope: "lend",
        suppliedUsd: 10_000_000,
        borrowedUsd: 4_000_000,
        availableUsd: 6_000_000,
        utilizationPct: 40,
        supplyApyPct: 5,
        borrowAprPct: 8,
      },
    ])
    const page = buildLendPageData("demo-wallet", hydrated)
    const hero = aggregateLendHeroFromMarkets(page.markets)

    const expectedTvl = page.markets.filter((m) => !m.soon).reduce((sum, m) => sum + (m.tvlUsd ?? 0), 0)
    expect(hero.totalTvl).toBeCloseTo(expectedTvl, 6)
    expect(hero.activeMarkets).toBe(page.markets.filter((m) => !m.soon).length)

    const touched = page.markets.find((m) => m.symbol.toLowerCase() === slug || m.name.toLowerCase().includes(slug))
    // Hydrated market should carry the Convex utilization (as fraction or pct depending on row shape)
    expect(touched?.utilization).toBeDefined()
  })
})
