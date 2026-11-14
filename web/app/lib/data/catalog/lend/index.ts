import { LEND_ASSET_GROUPS } from "./asset-groups"
import { LEND_FEATURED_ASSETS, LEND_FEATURED_SEQUENCE } from "./featured-assets"

export { LEND_ASSET_GROUPS, type LendAssetGroup, type LendAssetRow } from "./asset-groups"
export {
  LEND_FEATURED_ASSETS,
  LEND_FEATURED_SEQUENCE,
  type LendFeaturedAsset,
  type LendFeaturedAssetId,
} from "./featured-assets"

export const TOKENS: Array<{
  symbol: string
  name: string
  balance: number
  price: number
}> = []
for (const group of LEND_ASSET_GROUPS) {
  for (const row of group.rows) {
    TOKENS.push({
      symbol: row.symbol,
      name: row.name,
      balance: 0,
      price: 1,
    })
  }
}

export const MARKETS = [
  {
    symbol: "wstETH",
    name: "Lido Wrapped stETH",
    apy: 5.14,
    apyChange24h: 0.18,
    tvl: "$8.4M",
    utilization: 38,
    type: "Liquid",
    protocol: "Lido",
    color: "text-[#627EEA]",
    bg: "bg-[#EEF0FF]",
    soon: false,
    event: null,
  },
  {
    symbol: "WBTC",
    name: "Wrapped Bitcoin",
    apy: 3.48,
    apyChange24h: -0.06,
    tvl: "$0.9M",
    utilization: 29,
    type: "Med util",
    protocol: "WBTC",
    color: "text-[#F7931A]",
    bg: "bg-[#FFF5E5]",
    soon: false,
    event: null,
  },
  {
    symbol: "DAI",
    name: "MakerDAO Stablecoin",
    apy: 4.01,
    apyChange24h: 0.22,
    tvl: "$4.8M",
    utilization: 72,
    type: "Liquid",
    protocol: "MakerDAO",
    color: "text-[#EA580C]",
    bg: "bg-[#FEF0E7]",
    soon: false,
    event: "Rewards boosted",
  },
  {
    symbol: "cbBTC",
    name: "Coinbase Wrapped BTC",
    apy: 4.25,
    apyChange24h: 0.04,
    tvl: "$2.1M",
    utilization: 45,
    type: "Liquid",
    protocol: "Coinbase",
    color: "text-[#0052FF]",
    bg: "bg-[#E5EEFF]",
    soon: false,
    event: null,
  },
  {
    symbol: "USDe",
    name: "Ethena USDe",
    apy: 12.5,
    apyChange24h: 1.42,
    tvl: "$15.2M",
    utilization: 88,
    type: "High util",
    protocol: "Ethena",
    color: "text-[#18181B]",
    bg: "bg-[#F4F4F5]",
    soon: false,
    event: "Cap near full",
  },
  {
    symbol: "GHO",
    name: "Aave native stablecoin",
    apy: 0,
    apyChange24h: 0,
    tvl: "—",
    utilization: 0,
    type: "Soon",
    protocol: "Aave",
    color: "text-[#7928CA]",
    bg: "bg-[#F5EEFF]",
    soon: true,
    event: null,
  },
] as const

export const ACTIVITY = [
  {
    type: "deposit",
    asset: "USDC",
    amount: "+8,200",
    date: "Mar 19",
    icon: "↓",
    bg: "bg-brand/10",
    color: "text-brand",
  },
  {
    type: "deposit",
    asset: "USDT",
    amount: "+2,000",
    date: "Mar 19",
    icon: "↓",
    bg: "bg-brand/10",
    color: "text-brand",
  },
  {
    type: "interest",
    asset: "Interest",
    amount: "+$12.40",
    date: "Mar 18",
    icon: "💰",
    bg: "bg-blue-500/10",
    color: "text-blue-500",
  },
  {
    type: "deposit",
    asset: "ETH",
    amount: "+1.280",
    date: "Mar 17",
    icon: "↓",
    bg: "bg-brand/10",
    color: "text-brand",
  },
  {
    type: "withdraw",
    asset: "USDC",
    amount: "-500",
    date: "Mar 16",
    icon: "↑",
    bg: "bg-rose-500/10",
    color: "text-rose-500",
  },
  { type: "deposit", asset: "USDC", amount: "+500", date: "Mar 14", icon: "↓", bg: "bg-brand/10", color: "text-brand" },
] as const

export const mockChartData = [
  { time: "00:00", value: 11900 },
  { time: "04:00", value: 12050 },
  { time: "08:00", value: 12100 },
  { time: "12:00", value: 12180 },
  { time: "16:00", value: 12250 },
  { time: "20:00", value: 12340 },
  { time: "24:00", value: 12400 },
] as const

export const mockLendSharedSource = {
  getTokens() {
    return TOKENS
  },
  getMarkets() {
    return MARKETS
  },
  getActivity() {
    return ACTIVITY
  },
  getChartSeries() {
    return mockChartData
  },
  getFeaturedAssets() {
    return LEND_FEATURED_ASSETS
  },
  getFeaturedSequence() {
    return LEND_FEATURED_SEQUENCE
  },
  getAssetGroups() {
    return LEND_ASSET_GROUPS
  },
}
