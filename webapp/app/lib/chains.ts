/**
 * The app's chains. There are two, Ethereum and Base; the environment says which chain id each one
 * has on the network the app runs on (1 and 8453 on mainnet, the local or test chain ids
 * elsewhere), so moving between networks changes env only.
 */

export type ChainKey = "ethereum" | "base"

export const CHAIN_KEYS: readonly ChainKey[] = ["ethereum", "base"]

export const CHAIN_NAMES: Readonly<Record<ChainKey, string>> = { ethereum: "Ethereum", base: "Base" }

function envChainId(value: string | undefined, fallback: number): number {
  const parsed = Number(value?.trim())
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback
}

/** Chain id per chain. NEXT_PUBLIC_ variables are read by name so Next.js inlines them. */
export function chainIds(): Readonly<Record<ChainKey, number>> {
  return {
    ethereum: envChainId(process.env.NEXT_PUBLIC_AVANA_ETHEREUM_CHAIN_ID, 1),
    base: envChainId(process.env.NEXT_PUBLIC_AVANA_BASE_CHAIN_ID, 8453),
  }
}

/** The chain an EVM chain id belongs to on this network, or null for any other chain. */
export function chainKey(chainId: number | undefined): ChainKey | null {
  if (chainId === undefined) return null
  const ids = chainIds()
  return CHAIN_KEYS.find((key) => ids[key] === chainId) ?? null
}

/** "Ethereum" or "Base" for a chain id of this network, else null. */
export function chainName(chainId: number | undefined): string | null {
  const key = chainKey(chainId)
  return key ? CHAIN_NAMES[key] : null
}

/** The chain the app opens on (NEXT_PUBLIC_AVANA_CHAIN_ID); Ethereum when unset or unknown. */
export function defaultChainKey(): ChainKey {
  return chainKey(envChainId(process.env.NEXT_PUBLIC_AVANA_CHAIN_ID, 0)) ?? "ethereum"
}
