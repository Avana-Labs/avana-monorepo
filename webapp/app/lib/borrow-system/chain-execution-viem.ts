import type { PublicClient } from "viem"
import { chainPublicClient } from "@/app/lib/chain/public-client"
import { viemBatchChain, viemBatchWallet } from "@/app/lib/fees/fee-batch-viem"
import type { BorrowChain, BorrowWallet } from "@/app/lib/borrow-system/chain-execution"

/** What sending reads from one of the app's chains, over its shared read client; null without an RPC. */
export function viemBorrowChain(chainId: number): BorrowChain | null {
  const client = chainPublicClient(chainId)
  if (!client) return null
  return {
    readContract: (args) => client.readContract(args as Parameters<PublicClient["readContract"]>[0]),
    latestBlockTimestamp: async () => (await client.getBlock({ blockTag: "latest" })).timestamp,
    batchChain: (parameterStore) => viemBatchChain(client, parameterStore),
    waitForReceipt: async (hash) => (await client.waitForTransactionReceipt({ hash })).status,
  }
}

/** The connected wallet on `chainId`, or null when none is connected there. */
export async function connectedBorrowWallet(chainId: number): Promise<BorrowWallet | null> {
  try {
    const [{ getWalletClient }, { wagmiConfig }] = await Promise.all([import("wagmi/actions"), import("@/app/lib/web3/web3-provider")])
    const client = await getWalletClient(wagmiConfig, { chainId: chainId as never })
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
    // No wallet connected, or not on this chain.
    return null
  }
}
