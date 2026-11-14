import { getRegistryToken } from "@/app/lib/tokens/registry"

// Leaf module (no catalog imports) so light callers like the wallet rows can name tokens without
// pulling the Lend / swap catalogs that `token-names.ts` merges in.

/** Names for pool-only tokens that neither the Lend catalog nor the swap catalog lists. */
export const EXTRA_NAMES: Record<string, string> = {
  AURA: "Aura Finance",
  BRETT: "Brett",
  CRVUSD: "Curve USD",
  DAI: "Dai",
  DEGEN: "Degen",
  FRAX: "Frax",
  LUSD: "Liquity USD",
  MIM: "Magic Internet Money",
  OP: "Optimism",
  PYUSD: "PayPal USD",
  SDAI: "Savings Dai",
  SUSDE: "Staked USDe",
  TBTC: "tBTC",
  "USD+": "Overnight USD+",
  USDE: "Ethena USDe",
  USDS: "Sky Dollar",
  VIRTUAL: "Virtual Protocol",
  WELL: "Moonwell",
  WETH: "Wrapped Ether",
  ZORA: "Zora",
}

/** Name for a token outside the Lend and swap catalogs, or undefined. */
export function extraTokenName(symbol: string): string | undefined {
  const key = symbol.trim().toUpperCase()
  return EXTRA_NAMES[key] ?? getRegistryToken(key)?.name
}
