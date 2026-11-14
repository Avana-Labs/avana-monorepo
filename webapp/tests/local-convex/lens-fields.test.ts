// UI fields against a local services/convex seeded with the services fixture chain (scripts/local-convex-seed.ts).
// Each expected value is computed here from the fixture's Lens rows (readChainSnapshot over the fake chain), not from
// the Convex or webapp code under test, so the chain Lens → Convex → page view model is checked end to end.
//
// Run: AVANA_LOCAL_CONVEX_URL=http://127.0.0.1:3210 npm run test:local-convex
import { getAddress } from "viem"
import { beforeAll, describe, expect, it } from "vitest"
import {
  fakeChainClient,
  fixtureHubsChain,
  fixtureHubsDeployment,
} from "../../../services/common/src/views/fixtures.ts"
import { readChainSnapshot } from "../../../services/common/src/views/snapshot.ts"
import type { ChainSnapshot } from "../../../services/common/src/views/types.ts"

const LOCAL_URL = process.env.AVANA_LOCAL_CONVEX_URL
const SYMBOLS: Record<string, string> = {
  "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": "USDC",
  "0xdac17f958d2ee523a2206206994597c13d831ec7": "USDT",
  "0x40d16fc0246ad3160ccc09b8d0d3a2cd28ae6c2f": "GHO",
}
const RAY = 10n ** 27n

const units = (amount: string | bigint, decimals: number) => Number(BigInt(amount)) / 10 ** decimals
const usd8 = (value: string | bigint) => Number(BigInt(value)) / 1e8
const rayPct = (ray: string | bigint) => (Number(BigInt(ray)) / Number(RAY)) * 100
const apyPct = (ray: string | bigint) => (Math.exp(Number(BigInt(ray)) / Number(RAY)) - 1) * 100
const symbolOf = (token: string) => SYMBOLS[token.toLowerCase()] ?? token

describe.skipIf(!LOCAL_URL)("Lens-backed fields on a local Convex", () => {
  let lens: ChainSnapshot

  beforeAll(async () => {
    process.env.NEXT_PUBLIC_CONVEX_URL = LOCAL_URL
    process.env.CONVEX_URL = LOCAL_URL
    lens = await readChainSnapshot(fakeChainClient(fixtureHubsChain.later), fixtureHubsDeployment, {
      blockNumber: 1n,
      timestamp: Math.floor(Date.now() / 1000),
    })
  })

  describe("Lend list", () => {
    it("shows one row per Hub asset with its supply, utilization and supply APY", async () => {
      const { fetchLendPage } = await import("@/app/lib/data/providers/lend/fetch-lend-page")
      const page = await fetchLendPage()
      const rows = page.markets.map((m) => {
        const row = m as typeof m & { tvlUsd: number; utilization: number; apy: number }
        return { symbol: row.symbol, tvlUsd: row.tvlUsd, utilization: row.utilization, apy: row.apy }
      })
      const expected = lens.hubAssets
        .filter((a) => a.lend)
        .map((a) => ({
          symbol: symbolOf(a.underlying),
          tvlUsd: units(a.added, a.decimals) * usd8(a.priceUsd8),
          utilization: Math.round(a.utilizationBps / 100),
          apy: apyPct(a.supplyRateRay),
        }))
      const key = (r: { symbol: string; tvlUsd: number }) => `${r.symbol}:${r.tvlUsd.toFixed(2)}`
      expect(rows.map(key).sort()).toEqual(expected.map(key).sort())
      for (const want of expected) {
        const got = rows.find((r) => key(r) === key(want))!
        expect(got.utilization).toBe(want.utilization)
        expect(got.apy).toBeCloseTo(want.apy, 6)
      }
    })
  })

  describe("Borrow list", () => {
    it("shows each market's collateral value, LTV, risk premium and headroom", async () => {
      const { fetchBorrowPage } = await import("@/app/lib/data/providers/borrow/fetch-borrow-page")
      const page = await fetchBorrowPage()
      expect(page.poolCatalog).toHaveLength(lens.markets.length)
      for (const market of lens.markets) {
        const pool = page.poolCatalog.find((p) => p.id === `ethereum-market-${market.marketId}`)
        expect(pool, `market ${market.marketId}`).toBeDefined()
        expect(pool!.tvlUsd).toBeCloseTo(usd8(market.suppliedUsd8), 6)
        expect(pool!.ltv).toBe(market.collateralFactorBps / 100)
        expect(pool!.riskPremiumBps).toBe(market.collateralRiskBps)
        expect(pool!.availableUsd).toBeCloseTo(usd8(market.marketHeadroomUsd8), 6)
        expect(pool!.spoke.toLowerCase()).toBe(market.spoke.toLowerCase())
      }
    })

    it("lists as borrowable only the debt reserves of the market's CDP Spoke", async () => {
      const { fetchBorrowPage } = await import("@/app/lib/data/providers/borrow/fetch-borrow-page")
      const page = await fetchBorrowPage()
      for (const market of lens.markets) {
        const pool = page.poolCatalog.find((p) => p.id === `ethereum-market-${market.marketId}`)!
        const expected = lens.spokeReserves
          .filter((r) => r.spoke.toLowerCase() === market.spoke.toLowerCase())
          .map((r) => symbolOf(r.asset))
        // The page keys debt assets by slug; reserves of one token on one Spoke share a slug (see the map's gaps).
        expect([...new Set(pool.borrowableTokens.map((t) => t.symbol))].sort()).toEqual([...new Set(expected)].sort())
      }
    })

    it("shows each debt asset's borrow APR from its Hub's drawn rate", async () => {
      const { fetchBorrowPage } = await import("@/app/lib/data/providers/borrow/fetch-borrow-page")
      const page = await fetchBorrowPage()
      const drawnBySymbol = new Map<string, Set<string>>()
      for (const reserve of lens.spokeReserves) {
        const asset = lens.hubAssets.find(
          (a) => a.hub.toLowerCase() === reserve.hub.toLowerCase() && a.assetId === reserve.assetId,
        )
        if (!asset) continue
        const set = drawnBySymbol.get(symbolOf(reserve.asset)) ?? new Set<string>()
        set.add(rayPct(asset.drawnRateRay).toFixed(4))
        drawnBySymbol.set(symbolOf(reserve.asset), set)
      }
      expect(page.borrowableAssets.length).toBeGreaterThan(0)
      for (const asset of page.borrowableAssets) {
        expect(drawnBySymbol.get(asset.symbol), asset.id).toContain(asset.borrowApr.toFixed(4))
      }
    })
  })

  describe("Detail heroes", () => {
    it("show each market's checksummed pool address with its explorer link", async () => {
      const { getPoolDetailFromConvex } = await import("@/app/lib/borrow-detail/convex-detail")
      for (const market of lens.markets) {
        const detail = await getPoolDetailFromConvex(`ethereum-market-${market.marketId}`)
        const address = getAddress(market.pool)
        expect(detail?.hero.contract).toEqual({ address, explorerHref: `https://etherscan.io/address/${address}` })
      }
    })

    it("show a Hub asset's checksummed token address", async () => {
      const { getLendMarketDetailFromConvex } = await import("@/app/lib/lend-detail/convex-detail")
      const asset = lens.hubAssets.find((a) => a.lend && symbolOf(a.underlying) === "USDC")!
      const detail = await getLendMarketDetailFromConvex("ethereum-stable-usdc")
      expect(detail?.hero.contract?.address).toBe(getAddress(asset.underlying))
    })
  })
})
