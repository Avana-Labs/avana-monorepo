import { describe, expect, it } from "vitest"
import { buildPoolDetail } from "@/app/lib/borrow-detail/pool.mock"
import { formatPct } from "@/app/lib/borrow-detail/allocation"
import { formatCompactUsd } from "@/app/lib/borrow-market-rows"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { mergeConvexMarketSnapshots, type ConvexMarketSnapshot } from "@/app/lib/borrow-system/market-hydration"
import { resolvePoolDetailFromState } from "@/app/lib/borrow-system/read-model"
import { selectBorrowMarketSummaries } from "@/app/lib/borrow-system/selectors"
import { buildLendMarketDetail } from "@/app/lib/lend-detail"
import { buildLendCatalogBaselineState } from "@/app/lib/lend-system/mock"
import { mergeConvexLendSnapshots } from "@/app/lib/lend-system/market-hydration"
import { buildLendPageData } from "@/app/lib/lend-system/read-model"
import { injectAvailableUsdQuickStat } from "@/app/lib/detail-page/siloed-market-overlay"
import { buildMockMultiplySystemState } from "@/app/lib/multiply-system/mock"
import { mergeConvexMultiplySnapshots } from "@/app/lib/multiply-system/market-hydration"
import { buildMultiplyPageData } from "@/app/lib/multiply-system/read-model"

const WALLET = "demo-wallet"
const POOL_SLUG = "uni-v2-weth-usdc"

/**
 * After hydrate (+ shared snap fields), list row reference numbers must equal
 * detail quick-stat / detail-from-state inputs for the same slug — per product.
 */
describe("list ↔ detail parity after Convex hydrate", () => {
  it("borrow: list TVL/available/LTV/APY band match resolvePoolDetailFromState", () => {
    const state = buildMockBorrowSystemState(WALLET)
    const snap: ConvexMarketSnapshot = {
      slug: POOL_SLUG,
      scope: "pool",
      maxLtvPct: 77.5,
      premiumBps: 42,
      suppliedUsd: 33_000_000,
      borrowedUsd: 22_000_000,
      availableUsd: 11_000_000,
      utilizationPct: 66,
      supplyApyPct: 2.4,
      borrowAprPct: 4.2,
      tvlUsd: 33_000_000,
      volumeUsd: 4_000_000,
      feesUsd: 2_600,
    }
    const hydrated = mergeConvexMarketSnapshots(state, [snap])
    const listRow = selectBorrowMarketSummaries(hydrated, WALLET).find((r) => r.id === POOL_SLUG)
    expect(listRow).toBeDefined()
    if (!listRow) return

    expect(listRow.tvlUsd).toBe(snap.tvlUsd)
    expect(listRow.availableUsd).toBe(snap.availableUsd)
    expect(listRow.ltv).toBe(77.5)
    expect((listRow.aprMin + listRow.aprMax) / 2).toBeCloseTo(snap.supplyApyPct, 5)

    const detail = resolvePoolDetailFromState(hydrated, WALLET, POOL_SLUG)
    expect(detail).not.toBeNull()
    expect(detail!.quickStats.find((s) => s.id === "available")?.value).toBe(formatCompactUsd(listRow.availableUsd))
    expect(detail!.quickStats.find((s) => s.id === "supplyApy")?.value).toBe(
      formatPct((listRow.aprMin + listRow.aprMax) / 2, 2),
    )
    // Same builder path as detail: list row → buildPoolDetail must agree on available.
    expect(buildPoolDetail(listRow).quickStats.find((s) => s.id === "available")?.value).toBe(
      formatCompactUsd(snap.availableUsd),
    )
  })

  it("lend: list available/TVL/util/APY match detail overrides from the same snap", () => {
    const baseline = buildLendCatalogBaselineState(WALLET)
    const slug = Object.keys(baseline.markets)[0]!
    const snap = {
      slug,
      scope: "lend",
      suppliedUsd: 10_000_000,
      borrowedUsd: 4_000_000,
      availableUsd: 6_000_000,
      utilizationPct: 40,
      supplyApyPct: 5.25,
      borrowAprPct: 8.1,
    }
    const hydrated = mergeConvexLendSnapshots(baseline, [snap])
    const market = hydrated.markets[slug]!
    const page = buildLendPageData(WALLET, hydrated)

    const listAvailableUsd = market.availableLiquidity * market.assetPriceUsd
    const listTvlUsd = market.totalSupplied * market.assetPriceUsd
    expect(listAvailableUsd).toBeCloseTo(snap.availableUsd, 4)
    expect(listTvlUsd).toBeCloseTo(snap.suppliedUsd, 4)
    expect(market.utilization).toBeCloseTo(snap.utilizationPct / 100, 6)
    expect(market.supplyApy).toBeCloseTo(snap.supplyApyPct / 100, 6)

    const groupRow = page.assetGroups
      .flatMap((g) => g.rows)
      .find((r) => r.marketId === market.marketId || r.symbol.toUpperCase() === market.asset.symbol.toUpperCase())
    expect(groupRow?.availableLiquiditySortValue).toBeCloseTo(snap.availableUsd, 4)
    expect(groupRow?.supplyApyValue).toBeCloseTo(snap.supplyApyPct / 100, 6)
    expect(groupRow?.utilizationValue).toBeCloseTo(snap.utilizationPct / 100, 6)

    const detail = buildLendMarketDetail(market, {
      suppliedUsd: snap.suppliedUsd,
      borrowedUsd: snap.borrowedUsd,
      availableUsd: snap.availableUsd,
      utilizationPct: snap.utilizationPct,
      supplyApyPct: snap.supplyApyPct,
      borrowAprPct: snap.borrowAprPct,
    })
    expect(detail.quickStats.find((s) => s.id === "available")?.value).toBe(formatCompactUsd(snap.availableUsd))
    expect(detail.quickStats.find((s) => s.id === "supplyApy")?.value).toBe(formatPct(snap.supplyApyPct, 2))
    expect(detail.utilizationPct).toBe(snap.utilizationPct)
    expect(detail.borrowAprPct).toBe(snap.borrowAprPct)
  })

  it("multiply: list availableLiquidityUsd matches detail available quick-stat", () => {
    const state = buildMockMultiplySystemState(WALLET)
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
    const page = buildMultiplyPageData(WALLET, hydrated)
    const listAvailable = hydrated.markets[slug]!.economics.availableLiquidityUsd
    const row = page.lendRows.find((r) => r.href.endsWith(`/${slug}`))

    expect(listAvailable).toBe(snap.availableUsd)
    expect(row?.availableSecondary).toBe(formatCompactUsd(snap.availableUsd))

    const detailStats = injectAvailableUsdQuickStat(
      [{ id: "available", value: "$0" }],
      snap.availableUsd,
      formatCompactUsd,
    )
    expect(detailStats[0]!.value).toBe(row!.availableSecondary)
  })
})
