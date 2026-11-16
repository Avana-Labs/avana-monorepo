import { defineChain, type Chain } from "viem"
import { base, mainnet } from "wagmi/chains"
import { CHAIN_KEYS, CHAIN_NAMES, chainIds, defaultChainKey, type ChainKey } from "@/app/lib/chains"

/**
 * The app's two chains, Ethereum and Base, as the wallet sees them. The environment picks the network: each chain's id
 * comes from `chainIds()` and its RPC from NEXT_PUBLIC_RPC_ETHEREUM / NEXT_PUBLIC_RPC_BASE. On mainnet they are wagmi's
 * `mainnet` and `base`; on any other network (the local forks, a testnet) the chain is built from env and keeps the name
 * "Ethereum" or "Base", so a wallet that does not know it can add it (`wallet_addEthereumChain`).
 */

const KNOWN: Readonly<Record<ChainKey, Chain>> = { ethereum: mainnet, base }

/** The RPC of a chain on this network, when env sets one. NEXT_PUBLIC_ variables are read by name so Next.js inlines them. */
export function chainRpcUrl(key: ChainKey): string | undefined {
  const url = key === "ethereum" ? process.env.NEXT_PUBLIC_RPC_ETHEREUM : process.env.NEXT_PUBLIC_RPC_BASE
  return url?.trim() || undefined
}

export function appChain(key: ChainKey): Chain {
  const id = chainIds()[key]
  const rpc = chainRpcUrl(key)
  const known = KNOWN[key]
  if (id === known.id) return rpc ? { ...known, rpcUrls: { ...known.rpcUrls, default: { http: [rpc] } } } : known
  return defineChain({
    id,
    name: CHAIN_NAMES[key],
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: rpc ? [rpc] : [] } },
  })
}

/** Ethereum then Base on this network. */
export const APP_CHAINS = CHAIN_KEYS.map(appChain) as [Chain, ...Chain[]]
export const APP_CHAIN_IDS: readonly number[] = APP_CHAINS.map((chain) => chain.id)

/** The chain the app opens on (Ethereum unless NEXT_PUBLIC_AVANA_CHAIN_ID says Base). */
export const TARGET_CHAIN = appChain(defaultChainKey())
export const TARGET_CHAIN_ID = TARGET_CHAIN.id
export const TARGET_CHAIN_NAME = CHAIN_NAMES[defaultChainKey()]
