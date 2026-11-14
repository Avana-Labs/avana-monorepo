import { describe, expect, it } from "vitest"
import {
  BORROW_MARKET_OPTIONS,
  CHAIN_OPTIONS,
  EMPTY_MARKET_FILTERS,
  activeFilterCount,
  assetTabFor,
  borrowMarketForSpoke,
  borrowPoolFilterItem,
  buildAssetOptions,
  facetCounts,
  hubForSymbols,
  chainFilterId,
  lendFilterItem,
  matchesMarketFilters,
} from "@/app/lib/markets/filters"

describe("market filter model", () => {
  it("offers the chains of the deployments", () => {
    expect(CHAIN_OPTIONS.map((chain) => chain.label)).toEqual(["Ethereum", "Base", "Local"])
    expect(chainFilterId(1)).toBe("ethereum")
    expect(chainFilterId(8453)).toBe("base")
    expect(chainFilterId(31337)).toBe("local")
    expect(chainFilterId(10)).toBeNull()
  })

  it("matches every chain while rows carry no chain", () => {
    expect(lendFilterItem("USDC").chains).toEqual(["ethereum", "base", "local"])
    expect(borrowPoolFilterItem({ spoke: "aero-slipstream", visuals: [{ symbol: "USDC" }] }).chains).toEqual([
      "ethereum",
      "base",
      "local",
    ])
    expect(matchesMarketFilters(lendFilterItem("USDC"), { ...EMPTY_MARKET_FILTERS, chains: ["local"] })).toBe(true)
  })

  it("derives the hub from the token mix", () => {
    expect(hubForSymbols(["USDC"])).toBe("stable")
    expect(hubForSymbols(["USDC", "USDT"])).toBe("stable")
    expect(hubForSymbols(["wstETH", "WETH"])).toBe("correlated")
    expect(hubForSymbols(["cbBTC", "WBTC"])).toBe("correlated")
    expect(hubForSymbols(["WETH", "USDC"])).toBe("volatile")
    expect(hubForSymbols(["AAVE"])).toBe("volatile")
  })

  it("maps a borrow row to the DEX its CDP Spoke accepts", () => {
    expect(borrowMarketForSpoke("uniswap-v3")).toBe("uniswap-v3")
    expect(borrowMarketForSpoke("Uniswap V3")).toBe("uniswap-v3")
    expect(borrowMarketForSpoke("aerodrome-slipstream")).toBe("aerodrome-slipstream")
    expect(borrowMarketForSpoke("unknown")).toBeNull()
    expect(BORROW_MARKET_OPTIONS.map((option) => option.label)).toEqual(["Uniswap V3", "Aerodrome Slipstream"])
  })

  it("includes every constituent of a 3-token pool in its assets, once", () => {
    const item = borrowPoolFilterItem({
      spoke: "bal-weighted",
      visuals: [{ symbol: "USDC" }, { symbol: "WBTC" }],
      constituents: [{ symbol: "USDC" }, { symbol: "WBTC" }, { symbol: "ETH" }],
    })
    expect(item.assets).toEqual(["USDC", "WBTC", "ETH"])
  })

  it("dedupes asset options by symbol and sorts them by name, with a tab per family", () => {
    const options = buildAssetOptions([
      { symbol: "WETH", name: "Wrapped Ether" },
      { symbol: "weth", name: "Wrapped Ether" },
      { symbol: "USDC", name: "USD Coin" },
      { symbol: "AAVE", name: "Aave Token" },
    ])
    expect(options.map((option) => option.symbol)).toEqual(["AAVE", "USDC", "WETH"])
    expect(options.map((option) => option.tab)).toEqual(["other", "stable", "eth"])
    expect(assetTabFor("cbBTC")).toBe("btc")
  })

  it("ANDs facets and ORs options inside a facet", () => {
    const usdc = lendFilterItem("USDC")
    const weth = lendFilterItem("WETH")
    expect(matchesMarketFilters(usdc, EMPTY_MARKET_FILTERS)).toBe(true)
    expect(matchesMarketFilters(usdc, { ...EMPTY_MARKET_FILTERS, hubs: ["stable", "correlated"] })).toBe(true)
    expect(matchesMarketFilters(weth, { ...EMPTY_MARKET_FILTERS, hubs: ["stable", "correlated"] })).toBe(true)
    expect(matchesMarketFilters(weth, { ...EMPTY_MARKET_FILTERS, hubs: ["correlated"], markets: ["forex"] })).toBe(
      false,
    )
    expect(matchesMarketFilters(usdc, { ...EMPTY_MARKET_FILTERS, assets: ["usdc"] })).toBe(true)
    expect(matchesMarketFilters(usdc, { ...EMPTY_MARKET_FILTERS, chains: ["polygon"] })).toBe(false)
  })

  it("counts each facet's options against the other active facets only", () => {
    const items = [lendFilterItem("USDC"), lendFilterItem("USDT"), lendFilterItem("WETH")]
    const state = { ...EMPTY_MARKET_FILTERS, hubs: ["stable"] }
    // Hub counts ignore the hub selection itself...
    expect(facetCounts(items, state, "hubs").get("correlated")).toBe(1)
    // ...but chain counts honour it.
    expect(facetCounts(items, state, "chains").get("ethereum")).toBe(2)
    expect(facetCounts(items, state, "chains").get("polygon") ?? 0).toBe(0)
    expect(activeFilterCount({ ...state, assets: ["USDC", "USDT"] })).toBe(3)
  })
})
