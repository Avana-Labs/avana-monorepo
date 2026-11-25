import { createPublicClient, http, type Chain, type PublicClient } from "viem"
import { APP_CHAINS } from "@/app/lib/web3/target-chain"

/**
 * Multicall3, at the same address on Ethereum, Base, their test networks and the local nodes (services/common
 * `MULTICALL3_ADDRESS`). The chains built from env (a testnet, the local nodes) do not name it, so it is added here.
 */
export const MULTICALL3_ADDRESS = "0xcA11bde05977b3631167028862bE2a173976CA11" as const

const clients = new Map<number, PublicClient>()

/** The chain with a Multicall3 address, which viem needs to batch reads. */
export function withMulticall(chain: Chain): Chain {
  if (chain.contracts?.multicall3) return chain
  return { ...chain, contracts: { ...chain.contracts, multicall3: { address: MULTICALL3_ADDRESS } } }
}

/**
 * A read client for one of the app's chains (Ethereum or Base on this network), over the RPC env sets for it, or null
 * when the chain is not one of the app's or has no RPC. One client per chain, shared by every chain read. Contract reads
 * made in the same tick go out as one Multicall3 `eth_call` (a wallet's lend reserves and balances, its Lens accounts and
 * rewards), so a position refresh costs one request per chain, not one per reserve.
 */
export function chainPublicClient(chainId: number): PublicClient | null {
  const cached = clients.get(chainId)
  if (cached) return cached
  const chain = APP_CHAINS.find((c) => c.id === chainId)
  const url = chain?.rpcUrls.default.http[0]
  if (!chain || !url) return null
  const client = createPublicClient({ chain: withMulticall(chain), transport: http(url), batch: { multicall: true } }) as PublicClient
  clients.set(chainId, client)
  return client
}
