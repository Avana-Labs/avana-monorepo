import { createPublicClient, http, type Address, type PublicClient } from "viem"
import { viemBatchChain, viemBatchWallet } from "@/app/lib/fees/fee-batch-viem"
import { SWAP_CHAIN_ID } from "./catalog"
import type { SwapChain, SwapWallet } from "./swap-execution"

/** A read client for the Ethereum chain of this network (NEXT_PUBLIC_RPC_ETHEREUM), or null without one. */
export function swapPublicClient(): PublicClient | null {
  const url = process.env.NEXT_PUBLIC_RPC_ETHEREUM?.trim()
  return url ? createPublicClient({ transport: http(url) }) : null
}

/** What sending a swap reads from the chain, over a viem public client. */
export function viemSwapChain(client: PublicClient): SwapChain {
  return {
    readContract: (args) => client.readContract(args as Parameters<PublicClient["readContract"]>[0]),
    latestBlockTimestamp: async () => (await client.getBlock({ blockTag: "latest" })).timestamp,
    batchChain: (parameterStore: Address) => viemBatchChain(client, parameterStore),
    waitForReceipt: async (hash) => (await client.waitForTransactionReceipt({ hash })).status,
  }
}

/** The connected wallet on the swap chain, or null when none is connected there. */
export async function connectedSwapWallet(): Promise<SwapWallet | null> {
  try {
    const [{ getWalletClient }, { wagmiConfig }] = await Promise.all([import("wagmi/actions"), import("@/app/lib/web3/web3-provider")])
    const client = await getWalletClient(wagmiConfig, { chainId: SWAP_CHAIN_ID as never })
    const account = client.account.address
    return {
      account,
      ...viemBatchWallet(client, account),
      async waitForCalls(id) {
        const result = await client.waitForCallsStatus({ id })
        return { status: result.status === "success" ? "success" : "failure", hash: result.receipts?.at(-1)?.transactionHash ?? null }
      },
    }
  } catch {
    // No wallet connected, or not on the swap chain.
    return null
  }
}
