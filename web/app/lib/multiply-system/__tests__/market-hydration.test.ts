import { describe, expect, it } from "vitest"
import { calculateMaxLeverageApy } from "@/app/lib/multiply-engine"
import { buildMockMultiplySystemState } from "@/app/lib/multiply-system/mock"
import { mergeConvexMultiplySnapshots, multiplyAvailableLiquidityUsd } from "@/app/lib/multiply-system/market-hydration"
import { resolveMultiplyMarketDisplayMaxLeverage } from "@/app/lib/multiply-system/leverage-limits"
import { buildMultiplyPageData } from "@/app/lib/multiply-system/read-model"
import { injectAvailableUsdQuickStat } from "@/app/lib/detail-page/siloed-market-overlay"
import { formatCompactUsd } from "@/app/lib/borrow-sim"

describe("mergeConvexMultiplySnapshots", () => {
  it("updates estimatedMaxApy from Convex supply/borrow rates (aligns with trending)", () => {
    const state = buildMockMultiplySystemState("demo-wallet")
    const slug = Object.keys(state.markets)[0]!
    const existing = state.markets[slug]!

    const next = mergeConvexMultiplySnapshots(state, [
      {
        slug,
        scope: "multiply",
        name: "WETH / USDC",
        symbol: "WETH",
        suppliedUsd: 12_000_000,
        availableUsd: 5_400_000,
        borrowedUsd: 6_600_000,
        utilizationPct: 55,
        supplyApyPct: 4.5,
        borrowAprPct: 6.2,
      },
    ])

    const market = next.markets[slug]!
    const expected = calculateMaxLeverageApy({
      supplyApy: 0.045,
      borrowApy: 0.062,
      safeMaxMultiplier: resolveMultiplyMarketDisplayMaxLeverage(existing.risk.publicMaxMultiplier),
    })
    expect(market.economics.estimatedMaxApy).toBe(expected)
    expect(market.economics.supplyApy).toBe(0.045)
    expect(market.economics.borrowApy).toBe(0.062)
    expect(market.economics.utilizationPct).toBe(55)
    expect(market.collateralAsset.symbol).toBe("WETH")
    expect(market.borrowAsset.symbol).toBe("USDC")
  })

  it("maps availableLiquidityUsd from snap.availableUsd — not suppliedUsd", () => {
    const state = buildMockMultiplySystemState("demo-wallet")
    const slug = Object.keys(state.markets)[0]!

    const next = mergeConvexMultiplySnapshots(state, [
      {
        slug,
        scope: "multiply",
        suppliedUsd: 12_000_000,
        borrowedUsd: 6_600_000,
        availableUsd: 5_400_000,
        utilizationPct: 55,
        supplyApyPct: 4.5,
        borrowAprPct: 6.2,
      },
    ])

    expect(next.markets[slug]!.economics.availableLiquidityUsd).toBe(5_400_000)
    expect(next.markets[slug]!.economics.availableLiquidityUsd).not.toBe(12_000_000)
  })

  it("list row available matches detail available quick-stat from the same snap", () => {
    const state = buildMockMultiplySystemState("demo-wallet")
    const slug = Object.keys(state.markets)[0]!
    const snap = {
      slug,
      scope: "multiply",
      suppliedUsd: 12_000_000,
      borrowedUsd: 6_600_000,
      availableUsd: 5_400_000,
      utilizationPct: 55,
      supplyApyPct: 4.5,
      borrowAprPct: 6.2,
    }

    const hydrated = mergeConvexMultiplySnapshots(state, [snap])
    const page = buildMultiplyPageData("demo-wallet", hydrated)
    const listAvailable = hydrated.markets[slug]!.economics.availableLiquidityUsd
    const row = page.lendRows.find((r) => r.href.endsWith(`/${slug}`))

    expect(listAvailable).toBe(snap.availableUsd)
    expect(row?.availableSecondary).toBe(formatCompactUsd(snap.availableUsd))
    expect(row?.capacityFilledPct).toBe(snap.utilizationPct)
    expect(multiplyAvailableLiquidityUsd(snap)).toBe(snap.availableUsd)

    const detailStats = injectAvailableUsdQuickStat(
      [{ id: "available", value: "$0" }],
      snap.availableUsd,
      formatCompactUsd,
    )
    expect(detailStats[0]!.value).toBe(formatCompactUsd(snap.availableUsd))
    expect(detailStats[0]!.value).toBe(row!.availableSecondary)
  })

  it("ignores non-multiply scopes (silo isolation)", () => {
    const state = buildMockMultiplySystemState("demo-wallet")
    const slug = Object.keys(state.markets)[0]!
    const before = state.markets[slug]!.economics.availableLiquidityUsd

    const next = mergeConvexMultiplySnapshots(state, [
      {
        slug,
        scope: "lend",
        suppliedUsd: 99_000_000,
        availableUsd: 1,
        utilizationPct: 1,
        supplyApyPct: 1,
        borrowAprPct: 1,
      },
    ])
    expect(next.markets[slug]!.economics.availableLiquidityUsd).toBe(before)
  })
})
