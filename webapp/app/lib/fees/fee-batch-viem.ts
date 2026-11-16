import type { Account, Address, Chain, PublicClient, Transport, WalletClient } from "viem"
import { PARAMETER_STORE_ABI, type BatchChain, type BatchWallet, type Call } from "./fee-batch"

/** The chain side of an action batch over a viem public client and the release's ParameterStore address. */
export function viemBatchChain(client: PublicClient, parameterStore: Address): BatchChain {
  return {
    readFeeRecipient: () =>
      client.readContract({ address: parameterStore, abi: PARAMETER_STORE_ABI, functionName: "feeRecipient" }),
    async simulate(account, calls) {
      try {
        const { results } = await client.simulateCalls({ account, calls: calls.map(toViemCall) })
        return results.map((result) => result.status === "success")
      } catch {
        // eth_simulateV1 is not served by this node.
        return null
      }
    },
    async callSucceeds(account, call) {
      try {
        await client.call({ account, ...toViemCall(call) })
        return true
      } catch {
        return false
      }
    },
  }
}

function toViemCall(call: Call) {
  return { to: call.to, ...(call.data ? { data: call.data } : {}), ...(call.value ? { value: call.value } : {}) }
}

/** The wallet side over a viem wallet client: EIP-5792 batches when the wallet has the atomic capability. */
export function viemBatchWallet(client: WalletClient<Transport, Chain, Account>, account: Address): BatchWallet {
  return {
    async supportsAtomicBatch() {
      try {
        const capabilities = await client.getCapabilities({ account, chainId: client.chain.id })
        const status = (capabilities as { atomic?: { status?: string } }).atomic?.status
        return status === "supported" || status === "ready"
      } catch {
        // wallet_getCapabilities is not implemented: no EIP-5792.
        return false
      }
    },
    async sendCalls(calls) {
      const { id } = await client.sendCalls({ account, calls: calls.map(toViemCall), forceAtomic: true })
      return { id }
    },
    sendTransaction: (call) => client.sendTransaction({ account, chain: client.chain, ...toViemCall(call) }),
  }
}
