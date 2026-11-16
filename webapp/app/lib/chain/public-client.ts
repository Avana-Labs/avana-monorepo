import { createPublicClient, http, type PublicClient } from "viem"
import { APP_CHAINS } from "@/app/lib/web3/target-chain"

const clients = new Map<number, PublicClient>()

/**
 * A read client for one of the app's chains (Ethereum or Base on this network), over the RPC env sets for it, or null
 * when the chain is not one of the app's or has no RPC. One client per chain, shared by every chain read.
 */
export function chainPublicClient(chainId: number): PublicClient | null {
  const cached = clients.get(chainId)
  if (cached) return cached
  const chain = APP_CHAINS.find((c) => c.id === chainId)
  const url = chain?.rpcUrls.default.http[0]
  if (!chain || !url) return null
  const client = createPublicClient({ chain, transport: http(url) }) as PublicClient
  clients.set(chainId, client)
  return client
}
