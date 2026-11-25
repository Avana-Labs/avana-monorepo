import { describe, expect, it } from "vitest"
import {
  BORROW_MARKET_OPTIONS,
  CHAIN_OPTIONS,
  EMPTY_MARKET_FILTERS,
  activeFilterCount,
  assetTabFor,
  borrowMarketForSpoke,
  borrowPoolFilterItem,
  borrowSpokeOptions,
  buildAssetOptions,
  facetCounts,
  hubFilterOptions,
  chainFilterId,
  lendFilterItem,
  matchesMarketFilters,
} from "@/app/lib/markets/filters"

describe("market filter model", () => {
  it("offers the chains of the deployments", () => {
    expect(CHAIN_OPTIONS.map((chain) => chain.label)).toEqual(["Ethereum", "Base"])
    expect(chainFilterId(1)).toBe("ethereum")
    expect(chainFilterId(8453)).toBe("base")
    expect(chainFilterId(31337)).toBeNull()
    expect(chainFilterId(10)).toBeNull()
  })

  it("matches every chain while rows carry no chain", () => {
    expect(lendFilterItem({ symbol: "USDC", hub: "" }).chains).toEqual(["ethereum", "base"])
    expect(borrowPoolFilterItem({ spoke: "aero-slipstream", visuals: [{ symbol: "USDC" }] }).chains).toEqual([
      "ethereum",
      "base",
    ])
    expect(matchesMarketFilters(lendFilterItem({ symbol: "USDC", hub: "" }), { ...EMPTY_MARKET_FILTERS, chains: ["base"] })).toBe(true)
  })

  it("lists the Hubs of the rows, by address, with their labels", () => {
    const eth = { hub: "0xe1", hubLabel: "Avana Ethereum Hub" }
    const base = { hub: "0xb1", hubLabel: "Avana Base Hub" }
    const items = [
      lendFilterItem({ symbol: "USDC", ...eth }),
      lendFilterItem({ symbol: "WETH", ...base }),
      borrowPoolFilterItem({ spoke: "0xs1", hubId: "0xe1", hubLabel: "Avana Ethereum Hub", visuals: [{ symbol: "USDC" }] }),
      lendFilterItem({ symbol: "GHO", hub: "" }),
    ]
    expect(hubFilterOptions(items)).toEqual([
      { id: "0xb1", label: "Avana Base Hub", brand: true },
      { id: "0xe1", label: "Avana Ethereum Hub", brand: true },
    ])
    expect(items.filter((item) => matchesMarketFilters(item, { ...EMPTY_MARKET_FILTERS, hubs: ["0xe1"] }))).toHaveLength(2)
  })

  it("maps a borrow row to the DEX its CDP Spoke accepts", () => {
    expect(borrowMarketForSpoke("uniswap-v3")).toBe("uniswap-v3")
    expect(borrowMarketForSpoke("Uniswap V3")).toBe("uniswap-v3")
    expect(borrowMarketForSpoke("aerodrome-slipstream")).toBe("aerodrome-slipstream")
    expect(borrowMarketForSpoke("unknown")).toBeNull()
    expect(BORROW_MARKET_OPTIONS.map((option) => option.label)).toEqual(["Uniswap V3", "Aerodrome Slipstream"])
  })

  it("lists each CDP Spoke on its own, even two on one venue", () => {
    const spokeA = "0x00000000000000000000000000000000000000Aa"
    const spokeB = "0x00000000000000000000000000000000000000bb"
    const spokeC = "0x00000000000000000000000000000000000000cc"
    const options = borrowSpokeOptions([
      { spoke: spokeA, spokeName: "Avana Uniswap Blue Chip", venue: "Uniswap V3", dexId: "uniswap-v3" },
      { spoke: spokeA, venue: "Uniswap V3", dexId: "uniswap-v3" },
      { spoke: spokeB, venue: "Uniswap V3", dexId: "uniswap-v3" },
      { spoke: spokeC, venue: "Aero Slipstream", dexId: "aero-slipstream" },
    ])
    expect(options).toEqual([
      { id: spokeC, label: "Aero Slipstream", brand: true, iconSrc: "/asset-icons/aero.png" },
      { id: spokeA.toLowerCase(), label: "Avana Uniswap Blue Chip", brand: true, iconSrc: "/asset-icons/uni.png" },
      { id: spokeB, label: "Uniswap V3", brand: true, iconSrc: "/asset-icons/uni.png" },
    ])
    const item = borrowPoolFilterItem({ spoke: spokeA, dexId: "uniswap-v3", visuals: [{ symbol: "WETH" }, { symbol: "USDC" }] })
    expect(item.markets).toEqual([spokeA.toLowerCase()])
    expect(matchesMarketFilters(item, { ...EMPTY_MARKET_FILTERS, markets: [spokeB] })).toBe(false)
    expect(matchesMarketFilters(item, { ...EMPTY_MARKET_FILTERS, markets: [spokeA.toLowerCase()] })).toBe(true)
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
    const usdc = lendFilterItem({ symbol: "USDC", hub: "0xe1" })
    const weth = lendFilterItem({ symbol: "WETH", hub: "0xb1" })
    expect(matchesMarketFilters(usdc, EMPTY_MARKET_FILTERS)).toBe(true)
    expect(matchesMarketFilters(usdc, { ...EMPTY_MARKET_FILTERS, hubs: ["0xe1", "0xb1"] })).toBe(true)
    expect(matchesMarketFilters(weth, { ...EMPTY_MARKET_FILTERS, hubs: ["0xe1", "0xb1"] })).toBe(true)
    expect(matchesMarketFilters(weth, { ...EMPTY_MARKET_FILTERS, hubs: ["0xb1"], markets: ["forex"] })).toBe(false)
    expect(matchesMarketFilters(usdc, { ...EMPTY_MARKET_FILTERS, assets: ["usdc"] })).toBe(true)
    expect(matchesMarketFilters(usdc, { ...EMPTY_MARKET_FILTERS, chains: ["polygon"] })).toBe(false)
  })

  it("counts each facet's options against the other active facets only", () => {
    const items = [
      lendFilterItem({ symbol: "USDC", hub: "0xe1" }),
      lendFilterItem({ symbol: "USDT", hub: "0xe1" }),
      lendFilterItem({ symbol: "WETH", hub: "0xb1" }),
    ]
    const state = { ...EMPTY_MARKET_FILTERS, hubs: ["0xe1"] }
    // Hub counts ignore the hub selection itself...
    expect(facetCounts(items, state, "hubs").get("0xb1")).toBe(1)
    // ...but chain counts honour it.
    expect(facetCounts(items, state, "chains").get("ethereum")).toBe(2)
    expect(facetCounts(items, state, "chains").get("polygon") ?? 0).toBe(0)
    expect(activeFilterCount({ ...state, assets: ["USDC", "USDT"] })).toBe(3)
  })
})
