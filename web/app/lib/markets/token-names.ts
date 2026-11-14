import { SWAP_ASSETS } from "@/app/lib/swap-system/catalog"
import { getRegistryToken } from "@/app/lib/tokens/registry"
import { EXTRA_NAMES } from "@/app/lib/markets/extra-token-names"

let names: Map<string, string> | null = null

function nameMap(): Map<string, string> {
  if (names) return names
  names = new Map(Object.entries(EXTRA_NAMES))
  for (const asset of SWAP_ASSETS) names.set(asset.symbol.toUpperCase(), asset.name)
  return names
}

/** Human name for a token symbol, or undefined when no catalog knows it. */
export function tokenDisplayName(symbol: string): string | undefined {
  const key = symbol.trim().toUpperCase()
  return nameMap().get(key) ?? getRegistryToken(key)?.name
}
