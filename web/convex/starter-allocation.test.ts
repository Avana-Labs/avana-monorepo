import { describe, expect, test } from "vitest"
import {
  assertCatalogCanSatisfyStarter,
  buildStarterAllocationPlan,
  buildStarterLiquidTokenLegs,
  STARTER_BUCKETS,
  STARTER_EQUITY_USD,
  type StarterMarket,
  type StarterPricedMarket,
} from "./sandbox/starterAllocation"
import { SWAP_ENGINE_ASSETS, getSwapEngineAsset } from "./sandbox/swapQuoteEngine"

function catalog(scope: StarterMarket["scope"], count: number): StarterMarket[] {
  return Array.from({ length: count }, (_, index) => ({
    scope,
    slug: `${scope}-${String(index + 1).padStart(2, "0")}`,
  }))
}

/** A complete, fully-priced catalog just large enough to satisfy every starter bucket. */
function pricedCatalog(): StarterPricedMarket[] {
  const withPrice = (scope: StarterMarket["scope"], count: number): StarterPricedMarket[] =>
    Array.from({ length: count }, (_, index) => ({
      scope,
      slug: `${scope}-${String(index + 1).padStart(2, "0")}`,
      priceUsd: 100,
    }))
  return [
    ...withPrice("asset", STARTER_BUCKETS.liquid.count),
    ...withPrice("pool", STARTER_BUCKETS.collateral.count),
    ...withPrice("lend", STARTER_BUCKETS.lend.count),
    ...withPrice("multiply", STARTER_BUCKETS.multiply.count),
  ]
}

const MARKETS = [...catalog("asset", 64), ...catalog("pool", 64), ...catalog("lend", 25), ...catalog("multiply", 20)]

describe("starter allocation planner", () => {
  test("allocates exactly $1M across the configured diversified buckets", () => {
    const plan = buildStarterAllocationPlan("0xabc", MARKETS)
    expect(plan.totalEquityUsd).toBe(STARTER_EQUITY_USD)
    expect(plan.liquid).toHaveLength(STARTER_BUCKETS.liquid.count)
    expect(plan.collateral).toHaveLength(STARTER_BUCKETS.collateral.count)
    expect(plan.lend).toHaveLength(STARTER_BUCKETS.lend.count)
    expect(plan.multiply).toHaveLength(STARTER_BUCKETS.multiply.count)
    expect(
      Math.round(
        [...plan.liquid, ...plan.collateral, ...plan.lend, ...plan.multiply].reduce(
          (sum, leg) => sum + leg.amountUsd,
          0,
        ) * 100,
      ),
    ).toBe(STARTER_EQUITY_USD * 100)
  })

  test("is deterministic and changes selection for another wallet", () => {
    const first = buildStarterAllocationPlan("0xabc", MARKETS)
    expect(buildStarterAllocationPlan("0xAbC", MARKETS)).toEqual(first)
    expect(buildStarterAllocationPlan("0xdef", MARKETS)).not.toEqual(first)
  })

  test("distributes 10,000 wallets across every eligible market", () => {
    const selected = new Set<string>()
    for (let index = 0; index < 10_000; index += 1) {
      const plan = buildStarterAllocationPlan(`0x${index.toString(16).padStart(40, "0")}`, MARKETS)
      for (const leg of [...plan.liquid, ...plan.collateral, ...plan.lend, ...plan.multiply]) {
        selected.add(leg.marketSlug)
      }
    }
    expect(selected.size).toBe(MARKETS.length)
  })

  test("redistributes (never hard-fails) when a market scope is missing", () => {
    // Onboarding must complete even on a partial seed — the missing scope's budget is
    // spread over the buckets that do have markets, keeping the total at $1M.
    const plan = buildStarterAllocationPlan(
      "0xabc",
      MARKETS.filter((market) => market.scope !== "multiply"),
    )
    expect(plan.multiply).toHaveLength(0)
    expect(plan.liquid.length).toBeGreaterThan(0)
    const total = [...plan.liquid, ...plan.collateral, ...plan.lend, ...plan.multiply].reduce(
      (sum, leg) => sum + leg.amountUsd,
      0,
    )
    expect(Math.round(total * 100)).toBe(STARTER_EQUITY_USD * 100)
  })

  test("returns an empty plan (no throw) when the catalog is entirely unseeded", () => {
    const plan = buildStarterAllocationPlan("0xabc", [])
    expect(plan.liquid).toHaveLength(0)
    expect(plan.collateral).toHaveLength(0)
    expect(plan.lend).toHaveLength(0)
    expect(plan.multiply).toHaveLength(0)
  })
})

describe("assertCatalogCanSatisfyStarter (fail-closed onboarding gate)", () => {
  test("passes on a complete, fully-priced catalog", () => {
    expect(() => assertCatalogCanSatisfyStarter("0xabc", pricedCatalog())).not.toThrow()
  })

  test("throws when the catalog is entirely empty", () => {
    expect(() => assertCatalogCanSatisfyStarter("0xabc", [])).toThrow(/ONBOARDING_CATALOG_INCOMPLETE/)
  })

  test("throws, naming the bucket, when a scope is under-seeded", () => {
    const short = pricedCatalog().filter(
      (market) => !(market.scope === "multiply" && market.slug === `multiply-0${STARTER_BUCKETS.multiply.count}`),
    )
    expect(() => assertCatalogCanSatisfyStarter("0xabc", short)).toThrow(/ONBOARDING_CATALOG_INCOMPLETE:.*multiply/)
  })

  test("throws when a chosen leg has no positive price (undefined, 0, or non-finite)", () => {
    const unpriced = pricedCatalog().map((market) => ({ ...market, priceUsd: undefined }))
    expect(() => assertCatalogCanSatisfyStarter("0xabc", unpriced)).toThrow(
      /ONBOARDING_CATALOG_INCOMPLETE:.*positive price/,
    )
    const zeroPriced = pricedCatalog().map((market) => ({ ...market, priceUsd: 0 }))
    expect(() => assertCatalogCanSatisfyStarter("0xabc", zeroPriced)).toThrow(/positive price/)
  })
})

describe("buildStarterLiquidTokenLegs", () => {
  const prices: Record<string, number> = { usdc: 1, weth: 2000, wbtc: 40_000 }
  const tokens = [
    { id: "usdc", symbol: "USDC" },
    { id: "weth", symbol: "WETH" },
    { id: "wbtc", symbol: "WBTC" },
  ]
  const priceFor = (t: { id: string; symbol: string }) => prices[t.id] ?? 0

  test("splits the total to the cent and sizes each leg in token units", () => {
    const legs = buildStarterLiquidTokenLegs(tokens, priceFor, 100_000)
    expect(legs.map((l) => l.assetId)).toEqual(["usdc", "weth", "wbtc"])
    const sum = legs.reduce((s, l) => s + l.amountUsd, 0)
    expect(Math.round(sum * 100)).toBe(100_000 * 100) // exact to the cent
    const weth = legs.find((l) => l.assetId === "weth")!
    expect(weth.amount).toBeCloseTo(weth.amountUsd / 2000, 12)
  })

  test("seeds only REAL swap-catalog tokens (regression: no 'Unsupported asset' liquid rows)", () => {
    // Every non-LP swappable engine asset must resolve — the pre-fix seed used spoke-borrowable
    // composite ids ("uni-v2:wbtc") that getSwapEngineAsset/getSwapAsset can't resolve.
    const realTokens = SWAP_ENGINE_ASSETS.filter((a) => a.isSwapEnabled && !a.isLpToken)
    const legs = buildStarterLiquidTokenLegs(realTokens, () => 1, 100_000)
    for (const leg of legs) {
      const asset = getSwapEngineAsset(leg.assetId)
      expect(asset, `liquid leg ${leg.assetId} must be a real swap asset`).toBeDefined()
      expect(asset?.isLpToken).toBe(false)
      expect(leg.assetId).not.toContain(":") // never a spoke-borrowable composite slug
    }
  })

  test("degrades a non-positive or non-finite price to 1 rather than emitting Infinity/NaN", () => {
    const legs = buildStarterLiquidTokenLegs([{ id: "usdc", symbol: "USDC" }], () => 0, 5_000)
    expect(legs[0]!.priceUsd).toBe(1)
    expect(legs[0]!.amount).toBe(5_000)
    expect(Number.isFinite(legs[0]!.amount)).toBe(true)
  })

  test("returns [] for an empty token set", () => {
    expect(buildStarterLiquidTokenLegs([], priceFor, 100_000)).toEqual([])
  })
})
