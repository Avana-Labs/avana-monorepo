/**
 * Shared market categorisation for the filter chips on Lend / Borrow.
 *
 * The user's taxonomy has five buckets — BTC, ETH, Forex, Utility, Smart — but the
 * raw catalog only tags assets btc/eth/stable/crypto. This maps a base-asset symbol
 * to the five buckets (the approved "best-guess" mapping): BTC/ETH by token family,
 * Forex = fiat-pegged stables, Utility = governance/protocol tokens, Smart = the
 * curated remainder. Lend and Borrow share this bucketing so their filter chips agree.
 */

export type MarketCategory = "btc" | "eth" | "forex" | "utility" | "smart"

const BTC_SYMBOLS = new Set(["BTC", "WBTC", "CBBTC", "TBTC", "LBTC", "SOLVBTC", "EBTC"])
const ETH_SYMBOLS = new Set([
  "ETH",
  "WETH",
  "STETH",
  "WSTETH",
  "RETH",
  "CBETH",
  "WEETH",
  "FRXETH",
  "SFRXETH",
  "ETHX",
  "OSETH",
  "EZETH",
  "RSETH",
])
const FOREX_SYMBOLS = new Set([
  "USDC",
  "USDT",
  "DAI",
  "GHO",
  "USDE",
  "SUSDE",
  "FRAX",
  "FRXUSD",
  "CRVUSD",
  "USD+",
  "SDAI",
  "EURC",
  "EURS",
  "USDG",
  "RLUSD",
  "PYUSD",
  "USDS",
  "USD0",
  "GUSD",
  "LUSD",
  "3CRV",
  "USDP",
  "TUSD",
  "MIM",
])
const UTILITY_SYMBOLS = new Set([
  "UNI",
  "AAVE",
  "CRV",
  "LDO",
  "BAL",
  "GNO",
  "AURA",
  "AERO",
  "COMP",
  "MKR",
  "SNX",
  "CVX",
  "PENDLE",
  "RPL",
  "FXS",
  "SUSHI",
  "1INCH",
  "ENS",
  "ARB",
  "OP",
  "LINK",
])

export function categorizeMarket(symbol: string | null | undefined): MarketCategory {
  const key = (symbol ?? "").trim().toUpperCase()
  if (BTC_SYMBOLS.has(key)) return "btc"
  if (ETH_SYMBOLS.has(key)) return "eth"
  if (FOREX_SYMBOLS.has(key)) return "forex"
  if (UTILITY_SYMBOLS.has(key)) return "utility"
  // Anything not in a named family is a "smart" (curated) market.
  return "smart"
}

export type CategoryChip = { id: "all" | MarketCategory; label: string }

/** Chip rows per product, labelled to the user's spec. `all` is always first. */
export const CATEGORY_CHIPS: Record<"lend" | "borrow", CategoryChip[]> = {
  lend: [
    { id: "all", label: "All" },
    { id: "btc", label: "BTC Based" },
    { id: "eth", label: "ETH Based" },
    { id: "forex", label: "Forex Based" },
    { id: "utility", label: "Utility Based" },
    { id: "smart", label: "Smart Lend" },
  ],
  borrow: [
    { id: "all", label: "All" },
    { id: "btc", label: "BTC Pools" },
    { id: "eth", label: "ETH Pools" },
    { id: "forex", label: "Forex Pools" },
    { id: "utility", label: "Utility Pools" },
    { id: "smart", label: "Smart Pools" },
  ],
}

export function matchesCategory(symbol: string | null | undefined, chip: CategoryChip["id"]): boolean {
  return chip === "all" || categorizeMarket(symbol) === chip
}
