import { describe, expect, it } from "vitest"
import {
  ASSET_TVL_TARGET_USD,
  borrowPoolCapacityLabels,
  buildBorrowSeed,
  POOL_TVL_TARGET_USD,
} from "@/app/lib/convex-seed/build-seed"
import { BORROW_POOL_CATALOG } from "@/app/lib/borrow-sim"
import { listSpokeBorrowables } from "@/app/lib/borrow-system/registry"
import { LEND_MARKET_CATALOG } from "@/app/lib/lend-system/catalog"
import { MULTIPLY_MARKET_CATALOG } from "@/app/lib/multiply-system/catalog"

const ASOF = Date.UTC(2026, 5, 19) // fixed for reproducibility
// Derived from the catalogs so adding spokes/pools/assets doesn't require touching these pins.
const POOL_COUNT = BORROW_POOL_CATALOG.length // collateral pools
const ASSET_COUNT = listSpokeBorrowables().length // spoke-borrowable assets
const LEND_COUNT = LEND_MARKET_CATALOG.length
const MULTIPLY_COUNT = MULTIPLY_MARKET_CATALOG.length
const TOTAL_MARKETS = POOL_COUNT + ASSET_COUNT + LEND_COUNT + MULTIPLY_COUNT // pools + assets + lend + multiply

describe("buildBorrowSeed", () => {
  it("seeds product-siloed borrow/lend/multiply detail param tables", () => {
    const seed = buildBorrowSeed({ days: 1, asOf: ASOF })
    expect(seed.borrowRiskParameters.length).toBe(POOL_COUNT + ASSET_COUNT) // pools + assets
    expect(seed.borrowInterestRateModels.length).toBe(ASSET_COUNT) // assets only
    expect(seed.borrowLiquidationDaily.length).toBe(POOL_COUNT * 2) // 2 days per pool
    expect(seed.borrowPoolBorrowables.length).toBeGreaterThan(0)
    expect(seed.lendRiskParameters.length).toBe(LEND_COUNT)
    expect(seed.lendInterestRateModels.length).toBe(LEND_COUNT)
    expect(seed.multiplyRiskParameters.length).toBe(MULTIPLY_COUNT)
    expect(seed.multiplyLiquidationDaily.length).toBe(MULTIPLY_COUNT * 2)
    expect(seed.borrowMarketContent.length).toBe(POOL_COUNT + ASSET_COUNT)
    expect(seed.lendMarketContent.length).toBe(LEND_COUNT)
    expect(seed.multiplyMarketContent.length).toBe(MULTIPLY_COUNT)
    expect(seed.borrowRiskAssessments.length).toBe(POOL_COUNT + ASSET_COUNT)
    expect(seed.lendRiskAssessments.length).toBe(LEND_COUNT)
    expect(seed.multiplyRiskAssessments.length).toBe(MULTIPLY_COUNT)
    expect(seed.borrowRevenueDaily.length).toBe(POOL_COUNT + ASSET_COUNT) // pools + assets, days=1
    expect(seed.lendRevenueDaily.length).toBe(LEND_COUNT)
    expect(seed.multiplyRevenueDaily.length).toBe(MULTIPLY_COUNT)
    expect(seed.borrowDailyStats.length).toBe(POOL_COUNT + ASSET_COUNT)
    expect(seed.lendDailyStats.length).toBe(LEND_COUNT)
    expect(seed.multiplyDailyStats.length).toBe(MULTIPLY_COUNT)
    expect(seed.borrowMarkets.length).toBe(POOL_COUNT + ASSET_COUNT)
    expect(seed.lendMarkets.length).toBe(LEND_COUNT)
    expect(seed.multiplyMarkets.length).toBe(MULTIPLY_COUNT)
    expect(seed.borrowMarkets.every((m) => typeof m.reserveFactorPct === "number")).toBe(true)
    expect(seed.lendMarkets.every((m) => typeof m.reserveFactorPct === "number")).toBe(true)
    expect(seed.multiplyMarkets.every((m) => typeof m.reserveFactorPct === "number")).toBe(true)
    expect(seed.borrowMarkets.every((m) => m.rewardsApyPct === 0)).toBe(true)
    expect(seed.lendMarkets.some((m) => (m.rewardsApyPct ?? 0) > 0)).toBe(true)
    // Product rows never share slugs across silos incorrectly for IRM (borrow assets vs lend).
    const borrowIrm = new Set(seed.borrowInterestRateModels.map((r) => r.slug))
    const lendIrm = new Set(seed.lendInterestRateModels.map((r) => r.slug))
    for (const slug of lendIrm) expect(borrowIrm.has(slug)).toBe(false)
  })

  it("generates `days` daily stat + revenue rows per market", () => {
    const days = 30
    const seed = buildBorrowSeed({ days, asOf: ASOF })
    expect(seed.dailyStats.length).toBe(TOTAL_MARKETS * days)
    expect(seed.revenue.length).toBe(TOTAL_MARKETS * days)
  })

  it("seeds lend markets (scope 'lend', bare slug, content + risk)", () => {
    const seed = buildBorrowSeed({ days: 30, asOf: ASOF })
    const lend = seed.markets.filter((m) => m.scope === "lend")
    expect(lend.length).toBe(LEND_COUNT)
    for (const m of lend) {
      expect(m.slug).not.toContain(":") // bare marketId, e.g. "usdc"
      expect(m.category === "stable" || m.category === "crypto" || m.category === "stock").toBe(true)
    }
    const lendSlugs = new Set(lend.map((m) => m.slug))
    expect(seed.content.some((c) => lendSlugs.has(c.slug))).toBe(true)
    expect(seed.risk.some((r) => lendSlugs.has(r.slug) && r.breakdown.length >= 4)).toBe(true)
  })

  it("seeds multiply markets (scope 'multiply', bare slug, content + 5-factor risk)", () => {
    const seed = buildBorrowSeed({ days: 30, asOf: ASOF })
    const multiply = seed.markets.filter((m) => m.scope === "multiply")
    expect(multiply.length).toBe(MULTIPLY_COUNT)
    for (const m of multiply) {
      expect(m.slug).not.toContain(":") // bare market id, e.g. "eth-usdt"
      expect(m.name).toContain(" / ") // "ETH / USDT"
    }
    const multiplySlugs = new Set(multiply.map((m) => m.slug))
    expect(seed.content.some((c) => multiplySlugs.has(c.slug))).toBe(true)
    expect(seed.risk.some((r) => multiplySlugs.has(r.slug) && r.breakdown.length >= 5)).toBe(true)
    const about = seed.content.find((c) => c.slug === "aave-gho")
    expect(about?.stats.map((stat) => stat.label)).toEqual([
      "Vault Contract Address",
      "Token Contract Address",
      "Risk Manager Address",
      "Oracle Router Address",
    ])
    expect(about?.stats.every((stat) => stat.href?.startsWith("https://etherscan.io/address/"))).toBe(true)
  })

  it("uses route-matching slugs (asset = spoke-scoped id, pool = pool id)", () => {
    const seed = buildBorrowSeed({ days: 1, asOf: ASOF })
    const asset = seed.markets.find((m) => m.scope === "asset")!
    const pool = seed.markets.find((m) => m.scope === "pool")!
    expect(asset.slug).toMatch(/^[a-z0-9-]+:[a-z0-9]+$/) // e.g. uni-v2:usdc
    expect(pool.slug).not.toContain(":") // e.g. uni-v2-weth-usdc
    expect(asset.category === "stable" || asset.category === "crypto").toBe(true)
  })

  it("produces sane, finite daily values (utilization 1..99, non-negative money)", { timeout: 30_000 }, () => {
    const seed = buildBorrowSeed({ days: 90, asOf: ASOF })
    for (const row of seed.dailyStats) {
      expect(Number.isFinite(row.suppliedUsd)).toBe(true)
      expect(row.suppliedUsd).toBeGreaterThanOrEqual(0)
      expect(row.borrowedUsd).toBeGreaterThanOrEqual(0)
      expect(row.utilizationPct).toBeGreaterThanOrEqual(1)
      expect(row.utilizationPct).toBeLessThanOrEqual(99)
      expect(row.borrowAprPct).toBeGreaterThan(0)
      expect(row.day).toMatch(/^\d{4}-\d{2}-\d{2}$/)
    }
    // last day is the asOf date
    const lastDay = seed.dailyStats[seed.dailyStats.length - 1]!.day
    expect(lastDay).toBe(new Date(ASOF).toISOString().slice(0, 10))
  })

  it("calibrates the latest day to the canonical economy ($1.6B collateral / $700M loans / $900M credit)", () => {
    const seed = buildBorrowSeed({ days: 180, asOf: ASOF })
    const lastDay = new Date(ASOF).toISOString().slice(0, 10)
    const scopeBySlug = new Map(seed.markets.map((m) => [m.slug, m.scope]))
    let poolTvl = 0
    let assetTvl = 0
    for (const row of seed.dailyStats) {
      if (row.day !== lastDay) continue
      const scope = scopeBySlug.get(row.slug)
      if (scope === "pool") poolTvl += row.suppliedUsd
      else if (scope === "asset") assetTvl += row.suppliedUsd // lend excluded — own scale
    }
    // Calibrated to the targets (within rounding).
    expect(Math.abs(poolTvl - POOL_TVL_TARGET_USD)).toBeLessThan(POOL_TVL_TARGET_USD * 0.0001)
    expect(Math.abs(assetTvl - ASSET_TVL_TARGET_USD)).toBeLessThan(ASSET_TVL_TARGET_USD * 0.0001)
    const availableCredit = poolTvl - assetTvl
    expect(Math.round(availableCredit / 1e6)).toBe(900) // $900M
  })

  it("rewrites borrow risk deposit/borrow caps from post-calibration tips (not raw catalog)", () => {
    const seed = buildBorrowSeed({ days: 1, asOf: ASOF })
    const lastDay = new Date(ASOF).toISOString().slice(0, 10)
    const slug = "uni-v2-wbtc-usdc"
    const catalog = BORROW_POOL_CATALOG.find((p) => p.id === slug)
    expect(catalog).toBeDefined()
    const tip = seed.dailyStats.find((row) => row.slug === slug && row.day === lastDay)
    expect(tip).toBeDefined()
    const risk = seed.borrowRiskParameters.find((row) => row.slug === slug)
    expect(risk).toBeDefined()

    const fromTip = borrowPoolCapacityLabels(tip!.suppliedUsd, Math.max(0, tip!.suppliedUsd - tip!.borrowedUsd))
    const fromCatalog = borrowPoolCapacityLabels(catalog!.tvlUsd, catalog!.availableUsd)
    const deposit = risk!.parameters.find((p) => p.id === "depositCapacity")?.value
    const borrow = risk!.parameters.find((p) => p.id === "borrowCapacity")?.value

    expect(deposit).toBe(fromTip.depositCapacityLabel)
    expect(borrow).toBe(fromTip.borrowCapacityLabel)
    // Calibration scales markets down from catalog — caps must not stay on raw catalog size.
    expect(tip!.suppliedUsd).toBeLessThan(catalog!.tvlUsd)
    expect(deposit).not.toBe(fromCatalog.depositCapacityLabel)
  })

  it("is fully deterministic for a fixed asOf", () => {
    const a = buildBorrowSeed({ days: 14, asOf: ASOF })
    const b = buildBorrowSeed({ days: 14, asOf: ASOF })
    expect(JSON.stringify(a)).toBe(JSON.stringify(b))
  })

  it("scales daily rows with the window (365-day default ≈ 46.7k per table)", () => {
    const seed = buildBorrowSeed({ days: 365, asOf: ASOF })
    expect(seed.dailyStats.length).toBe(TOTAL_MARKETS * 365)
    expect(seed.revenue.length).toBe(TOTAL_MARKETS * 365)
  })

  it("seeds a rich risk breakdown + metrics (not an empty stub)", () => {
    const seed = buildBorrowSeed({ days: 1, asOf: ASOF })
    expect(seed.risk.length).toBe(TOTAL_MARKETS)
    for (const r of seed.risk) {
      // assets get 4 factors, pools get 5 — never the old empty stub.
      expect(r.breakdown.length).toBeGreaterThanOrEqual(4)
      expect(r.metrics.length).toBeGreaterThanOrEqual(1)
      expect(r.premiumBps).toBeGreaterThan(0)
      expect(r.breakdown.reduce((s, b) => s + b.bps, 0)).toBeGreaterThan(0)
      for (const b of r.breakdown) expect(b.description.length).toBeGreaterThan(0)
    }
  })

  it("seeds per-asset allocation rows (latest day, shares ~sum to 100, calibrated values)", () => {
    const seed = buildBorrowSeed({ days: 30, asOf: ASOF })
    const lastDay = new Date(ASOF).toISOString().slice(0, 10)
    expect(seed.allocation.length).toBeGreaterThan(0)
    for (const row of seed.allocation) {
      expect(row.day).toBe(lastDay)
      expect(row.assetSlug).toContain(":") // asset = spoke-scoped id
      expect(row.poolSlug).not.toContain(":") // pool = pool id
      expect(row.sharePct).toBeGreaterThanOrEqual(0)
      expect(row.sharePct).toBeLessThanOrEqual(100)
      expect(Number.isFinite(row.valueUsd)).toBe(true)
      expect(row.valueUsd).toBeGreaterThanOrEqual(0)
    }
    // Per asset, the shares are re-scaled to sum to ~100.
    const sharesByAsset = new Map<string, number>()
    for (const row of seed.allocation) {
      sharesByAsset.set(row.assetSlug, (sharesByAsset.get(row.assetSlug) ?? 0) + row.sharePct)
    }
    for (const [, sum] of sharesByAsset) expect(Math.abs(sum - 100)).toBeLessThan(0.5)
  })

  it("anchors allocation value to the calibrated per-asset supplied (sums ≤ asset TVL band)", () => {
    const seed = buildBorrowSeed({ days: 60, asOf: ASOF })
    const lastDay = new Date(ASOF).toISOString().slice(0, 10)
    const suppliedByAsset = new Map<string, number>()
    for (const s of seed.dailyStats) {
      if (s.day === lastDay) suppliedByAsset.set(s.slug, s.suppliedUsd)
    }
    const valueByAsset = new Map<string, number>()
    for (const row of seed.allocation) {
      valueByAsset.set(row.assetSlug, (valueByAsset.get(row.assetSlug) ?? 0) + row.valueUsd)
    }
    // Allocation values sum to (very close to) the asset's calibrated supplied,
    // so the detail "Value" column reconciles with the headline TVL. The small
    // residual is share-rescale + per-row dollar rounding.
    for (const [assetSlug, value] of valueByAsset) {
      const supplied = suppliedByAsset.get(assetSlug) ?? 0
      if (supplied > 0) expect(Math.abs(value - supplied) / supplied).toBeLessThan(0.01)
    }
  })
})
