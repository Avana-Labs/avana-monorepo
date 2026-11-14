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
  lendFilterItem,
  loopCategories,
  matchesMarketFilters,
  multiplyFilterItem,
} from "@/app/lib/markets/filters"

describe("market filter model", () => {
  it("offers exactly the requested chains, testnet first", () => {
    expect(CHAIN_OPTIONS.map((chain) => chain.label)).toEqual(["Testnet", "Ethereum", "Avalanche", "Robinhood"])
  })

  it("puts every market on testnet only until mainnet", () => {
    expect(lendFilterItem("USDC").chains).toEqual(["testnet"])
    expect(multiplyFilterItem("AVAX", "USDC").chains).toEqual(["testnet"])
    expect(borrowPoolFilterItem({ spoke: "aero-basic-stable", visuals: [{ symbol: "USDC" }] }).chains).toEqual([
      "testnet",
    ])
    expect(matchesMarketFilters(lendFilterItem("USDC"), { ...EMPTY_MARKET_FILTERS, chains: ["ethereum"] })).toBe(false)
  })

  it("derives the hub from the token mix", () => {
    expect(hubForSymbols(["USDC"])).toBe("stable")
    expect(hubForSymbols(["USDC", "USDT"])).toBe("stable")
    expect(hubForSymbols(["wstETH", "WETH"])).toBe("correlated")
    expect(hubForSymbols(["cbBTC", "WBTC"])).toBe("correlated")
    expect(hubForSymbols(["WETH", "USDC"])).toBe("volatile")
    expect(hubForSymbols(["AAVE"])).toBe("volatile")
  })

  it("maps every live borrow spoke to a DEX market and keeps roadmap DEXes as Soon", () => {
    expect(borrowMarketForSpoke("uni-v2")).toBe("uniswap-v2")
    expect(borrowMarketForSpoke("uni-v3-stable")).toBe("uniswap-v3")
    expect(borrowMarketForSpoke("uni-robinhood-stocks")).toBe("uniswap-v3")
    expect(borrowMarketForSpoke("curve-correlated")).toBe("curve")
    expect(borrowMarketForSpoke("aero-basic-volatile")).toBe("aerodrome-basic")
    expect(borrowMarketForSpoke("aero-slipstream-bluechip")).toBe("aerodrome-slipstream")
    expect(borrowMarketForSpoke("bal-reclamm")).toBe("balancer")
    expect(BORROW_MARKET_OPTIONS.filter((option) => option.soon).map((option) => option.label)).toEqual([
      "CoW Swap",
      "Uniswap V4",
      "Sushi",
      "Balancer V2",
    ])
  })

  it("includes every constituent of a 3-token pool in its assets, once", () => {
    const item = borrowPoolFilterItem({
      spoke: "bal-weighted",
      visuals: [{ symbol: "USDC" }, { symbol: "WBTC" }],
      constituents: [{ symbol: "USDC" }, { symbol: "WBTC" }, { symbol: "ETH" }],
    })
    expect(item.assets).toEqual(["USDC", "WBTC", "ETH"])
  })

  it("keeps the old Multiply chip semantics as loop categories", () => {
    expect(loopCategories("wstETH", "WETH").sort()).toEqual(["eth", "smart"])
    expect(loopCategories("USDC", "USDT").sort()).toEqual(["forex", "smart"])
    expect(loopCategories("WBTC", "USDC")).toEqual(["btc"])
    expect(loopCategories("AAVE", "USDC")).toEqual(["utility"])
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
    expect(matchesMarketFilters(usdc, { ...EMPTY_MARKET_FILTERS, chains: ["avalanche"] })).toBe(false)
  })

  it("counts each facet's options against the other active facets only", () => {
    const items = [
      lendFilterItem("USDC"),
      lendFilterItem("USDT"),
      lendFilterItem("WETH"),
      multiplyFilterItem("AVAX", "USDC"),
    ]
    const state = { ...EMPTY_MARKET_FILTERS, hubs: ["stable"] }
    // Hub counts ignore the hub selection itself...
    expect(facetCounts(items, state, "hubs").get("correlated")).toBe(1)
    // ...but chain counts honour it.
    expect(facetCounts(items, state, "chains").get("testnet")).toBe(2)
    expect(facetCounts(items, state, "chains").get("ethereum") ?? 0).toBe(0)
    expect(activeFilterCount({ ...state, assets: ["USDC", "USDT"] })).toBe(3)
  })
})
