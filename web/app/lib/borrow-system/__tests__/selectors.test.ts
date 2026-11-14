import { describe, expect, it } from "vitest"
import { BORROW_POOL_CATALOG } from "@/app/lib/borrow-sim"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { calculateSpokeCreditMetrics } from "@/app/lib/credit-engine"
import type { BorrowAssetVisual } from "@/app/lib/borrow-sim"
import {
  selectAllAvailableCollateralPools,
  selectBorrowableAssets,
  selectBorrowCollateralPools,
  selectBorrowMarketSummaries,
  selectInitialBorrowDebts,
  selectWalletBorrowSnapshot,
  toPairVisuals,
} from "@/app/lib/borrow-system/selectors"

const sampleVisual = (symbol: string): BorrowAssetVisual => ({
  symbol,
  shortLabel: symbol.slice(0, 3),
  iconUrl: undefined,
  bgClass: "bg-brand",
  textClass: "text-brand-foreground",
})

describe("borrow system selectors", () => {
  it("projects canonical borrow state into borrow page rows", () => {
    const state = buildMockBorrowSystemState("demo-wallet")

    const markets = selectBorrowMarketSummaries(state, "demo-wallet")
    const allAssets = selectBorrowableAssets(state, "demo-wallet")
    const assets = selectBorrowableAssets(state, "demo-wallet", "uni-v3-bluechip-weth-usdc")
    const pools = selectBorrowCollateralPools(state, "demo-wallet")
    const debts = selectInitialBorrowDebts(state, "demo-wallet")
    const snapshot = selectWalletBorrowSnapshot(state, "demo-wallet")

    expect(markets.length).toBeGreaterThan(5)
    expect(allAssets).toHaveLength(71)
    expect(assets.length).toBeGreaterThan(1)
    expect(assets.every((asset) => asset.id.startsWith("uni-v3-bluechip:"))).toBe(true)
    expect(assets.map((asset) => asset.id)).toContain("uni-v3-bluechip:usdc")
    expect(pools).toHaveLength(3)
    expect(debts["uni-v3-bluechip-weth-usdc"]).toBe(1200)
    expect(debts["uni-v3-bluechip-wbtc-weth"]).toBeUndefined()
    expect(snapshot.totalBorrowedUsd).toBe(2000)
    expect(snapshot.availableCreditUsd).toBeGreaterThan(0)
  })

  it("normalizes stale Convex SVG token paths to bundled PNG assets", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    for (const market of Object.values(state.markets)) {
      for (const visual of market.display.visuals) visual.iconUrl = `/asset-icons/${visual.symbol.toLowerCase()}.svg`
    }

    const markets = selectBorrowMarketSummaries(state, "demo-wallet")
    expect(markets.flatMap((market) => market.visuals).every((visual) => visual.iconUrl?.endsWith(".png"))).toBe(true)
    expect(markets.flatMap((market) => market.visuals).some((visual) => visual.iconUrl?.endsWith(".svg"))).toBe(false)
  })

  it("surfaces a real, per-market risk premium on the borrow list (not a uniform 0.00%)", () => {
    // A browsing wallet has no positions, so the wallet-scoped premium is 0 for every spoke.
    // The list must instead show the intrinsic per-market premium from the catalog.
    const state = buildMockBorrowSystemState("browsing-wallet")
    const markets = selectBorrowMarketSummaries(state, "browsing-wallet")
    const catalogById = new Map(BORROW_POOL_CATALOG.map((row) => [row.id, row.riskPremiumBps]))

    // Not all zero.
    expect(markets.some((market) => market.riskPremiumBps > 0)).toBe(true)
    // More than one distinct value across the list — the column is genuinely informative.
    expect(new Set(markets.map((market) => market.riskPremiumBps)).size).toBeGreaterThan(1)
    // Each row matches the catalog premium the pool detail renders.
    for (const market of markets) {
      const expected = catalogById.get(market.id)
      if (expected !== undefined) expect(market.riskPremiumBps).toBe(expected)
    }
  })

  it("exposes every market as an available collateral pool (pre-loaded picker)", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const pledged = selectBorrowCollateralPools(state, "demo-wallet")
    const available = selectAllAvailableCollateralPools(state, "demo-wallet")

    // Available is the full market catalog — strictly a superset of pledged pools.
    expect(available.length).toBe(Object.keys(state.markets).length)
    expect(available.length).toBeGreaterThan(pledged.length)
  })

  it("reports spoke-scoped in-scope collateral so the card matches 'Net collateral in spoke' (#86)", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const available = selectAllAvailableCollateralPools(state, "demo-wallet")

    // The reported repro: a bluechip market the wallet has NOT pledged must show
    // the spoke's in-scope collateral ($6,300), not $0.00, because the borrow is
    // allowed against the bluechip spoke's pledged collateral.
    const unpledgedBluechip = available.find((pool) => pool.id === "uni-v3-bluechip-weth-usdt")
    const spokeCollateralUsd =
      Number(calculateSpokeCreditMetrics(state, "demo-wallet", "uni-v3-bluechip").poolCollateralValueUsd6) / 1e6
    expect(spokeCollateralUsd).toBeCloseTo(6300, 4)
    expect(unpledgedBluechip?.collateralUsd).toBeCloseTo(spokeCollateralUsd, 4)
    expect(unpledgedBluechip?.collateralUsd).toBeGreaterThan(0)

    // Every pool in a spoke with collateral agrees on the in-scope value.
    for (const pool of available) {
      const spokeId = state.markets[pool.id]?.spokeId
      if (!spokeId) continue
      const inScope = Number(calculateSpokeCreditMetrics(state, "demo-wallet", spokeId).poolCollateralValueUsd6) / 1e6
      expect(pool.collateralUsd).toBeCloseTo(inScope, 4)
    }
  })

  it("returns the full catalog even for a wallet with no positions", () => {
    const state = buildMockBorrowSystemState("home-demo-wallet")
    const available = selectAllAvailableCollateralPools(state, "no-such-wallet")
    expect(available.length).toBe(Object.keys(state.markets).length)
    expect(available.every((pool) => pool.collateralUsd === 0)).toBe(true)
  })

  // Regression: the collateral table renders every market as a two-token pair and
  // dereferences visuals[0]/visuals[1] unguarded. A market with <2 visuals must not
  // crash the client-rendered workspace — every row must expose a 2-tuple.
  describe("toPairVisuals (crash guard for <2-leg markets)", () => {
    it("pads a single-token market to a 2-tuple by reusing the sole leg", () => {
      const pair = toPairVisuals([sampleVisual("MOG")])
      expect(pair).toHaveLength(2)
      expect(pair[0].symbol).toBe("MOG")
      expect(pair[1].symbol).toBe("MOG")
    })

    it("returns a well-formed 2-tuple for an empty visuals array (no undefined access)", () => {
      const pair = toPairVisuals([])
      expect(pair).toHaveLength(2)
      expect(pair[0]).toBeDefined()
      expect(pair[1]).toBeDefined()
      expect(() => `${pair[0].symbol} / ${pair[1].symbol}`).not.toThrow()
    })

    it("preserves both legs for a normal two-token market", () => {
      const pair = toPairVisuals([sampleVisual("WBTC"), sampleVisual("USDC")])
      expect(pair[0].symbol).toBe("WBTC")
      expect(pair[1].symbol).toBe("USDC")
    })
  })

  it("guarantees every market summary row exposes exactly two visuals", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const markets = selectBorrowMarketSummaries(state, "demo-wallet")
    expect(markets.length).toBeGreaterThan(0)
    for (const market of markets) {
      expect(market.visuals).toHaveLength(2)
      expect(market.visuals[0]?.symbol).toBeTruthy()
      expect(market.visuals[1]?.symbol).toBeTruthy()
    }
  })
})
