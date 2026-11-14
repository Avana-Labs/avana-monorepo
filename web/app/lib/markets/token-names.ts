import { LEND_ASSET_GROUPS } from "@/app/lib/data/catalog/lend/asset-groups"
import { SWAP_ASSETS } from "@/app/lib/swap-system/catalog"
import { getRegistryToken } from "@/app/lib/tokens/registry"
import { EXTRA_NAMES } from "@/app/lib/markets/extra-token-names"

let names: Map<string, string> | null = null

function nameMap(): Map<string, string> {
  if (names) return names
  names = new Map(Object.entries(EXTRA_NAMES))
  for (const asset of SWAP_ASSETS) names.set(asset.symbol.toUpperCase(), asset.name)
  // The Lend catalog's names are the product's canonical ones, so they win.
  for (const row of LEND_ASSET_GROUPS.flatMap((group) => group.rows)) names.set(row.symbol.toUpperCase(), row.name)
  return names
}

/** Human name for a token symbol, or undefined when no catalog knows it. */
export function tokenDisplayName(symbol: string): string | undefined {
  const key = symbol.trim().toUpperCase()
  return nameMap().get(key) ?? getRegistryToken(key)?.name
}
