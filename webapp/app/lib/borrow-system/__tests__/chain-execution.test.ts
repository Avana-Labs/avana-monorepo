import { decodeFunctionData, getAddress, type Address } from "viem"
import { describe, expect, it, vi } from "vitest"
import { AAVE_ADAPTER_ABI, executeBorrowOnChain, type BorrowChain, type BorrowWallet } from "@/app/lib/borrow-system/chain-execution"
import type { ChainBorrowRefs } from "@/app/lib/borrow-system/chain-refs"
import type { TransactionIntent } from "@/app/lib/borrow-system/contracts"
import { emptyBorrowSystemState } from "@/app/lib/borrow-system/market-hydration"
import { RAY } from "@/app/lib/borrow-system/model"
import { DEFAULT_FEE_RULES } from "@/convex/lib/fees"

const WALLET = getAddress("0x00000000000000000000000000000000000000c1")
const LENS = getAddress("0x00000000000000000000000000000000000000d1")
const ADAPTER = getAddress("0x00000000000000000000000000000000000000d2")
const STORE = getAddress("0x00000000000000000000000000000000000000d3")
const USDC = getAddress("0x00000000000000000000000000000000000000e1")
const SPOKE = "0x00000000000000000000000000000000000000aa"
const PROXY = "0x00000000000000000000000000000000000000bb"

const refs: ChainBorrowRefs = {
  wallet: WALLET,
  lenses: [{ chainId: 31337, lens: LENS }],
  accounts: [{ chainId: 31337, marketId: "7", spoke: SPOKE, proxy: PROXY, poolSlug: "weth-usdc-30" }],
  debtReserves: [{ chainId: 31337, spoke: SPOKE, reserveId: "1", asset: USDC, assetSlug: "usdc-a", decimals: 6, priceUsd8: "100000000" }],
}

function harness(opts: { atomic?: boolean; reverted?: boolean } = {}) {
  const sent: { to: Address; data?: `0x${string}` }[][] = []
  const chain: BorrowChain = {
    readContract: vi.fn(async ({ functionName }: { functionName: string }) => {
      if (functionName === "ADAPTER") return ADAPTER
      if (functionName === "PARAMETER_STORE") return STORE
      if (functionName === "borrowNonce") return 3n
      if (functionName === "feeRecipient") return getAddress("0x00000000000000000000000000000000000000f1")
      throw new Error(`unexpected read ${functionName}`)
    }),
    latestBlockTimestamp: async () => 1_000n,
    batchChain: () => ({
      readFeeRecipient: async () => getAddress("0x00000000000000000000000000000000000000f1"),
      callSucceeds: async () => true,
      simulate: async () => null,
    }),
    waitForReceipt: async () => (opts.reverted ? "reverted" : "success"),
  }
  const wallet: BorrowWallet = {
    account: WALLET,
    supportsAtomicBatch: async () => opts.atomic ?? false,
    sendCalls: async (calls: { to: Address; data?: `0x${string}` }[]) => {
      sent.push(calls)
      return { id: "batch-1" }
    },
    sendTransaction: async (call: { to: Address; data?: `0x${string}` }) => {
      sent.push([call])
      return `0x${"ab".repeat(32)}`
    },
    waitForCalls: async () => ({ status: opts.reverted ? "failure" : "success", hash: `0x${"cd".repeat(32)}` }),
  } as unknown as BorrowWallet
  const state = emptyBorrowSystemState(WALLET)
  state.accounts[WALLET]!.debtPositions.push({
    id: "debt:31337:7:1",
    assetId: "usdc-a",
    baseAssetId: "usdc-a",
    spokeId: SPOKE,
    marketId: "weth-usdc-30",
    debtSharesUsd6: 1_200_000_000n,
    debtIndexRay: RAY,
    borrowRateWad: 0n,
    principalBorrowedUsd6: 1_200_000_000n,
  })
  const onConfirmed = vi.fn()
  const deps = {
    refs: (w: string) => (w === WALLET ? refs : null),
    chain: () => chain,
    wallet: async () => wallet,
    state: () => state,
    onConfirmed,
    rules: DEFAULT_FEE_RULES,
    now: () => 5,
  }
  return { deps, sent, onConfirmed }
}

const intent = (over: Partial<TransactionIntent>): TransactionIntent => ({
  id: "intent-1",
  actionType: "borrow",
  walletId: WALLET,
  amountUsd6: 0n,
  requestedAt: 0,
  simulated: false,
  ...over,
})

const adapterCall = (calls: { to: Address; data?: `0x${string}` }[]) => {
  const call = calls.find((c) => c.to === ADAPTER)!
  return decodeFunctionData({ abi: AAVE_ADAPTER_ABI, data: call.data! })
}

describe("executeBorrowOnChain", () => {
  it("borrows the USD amount in token units with the account's nonce", async () => {
    const { deps, sent, onConfirmed } = harness()
    const r = await executeBorrowOnChain(deps, intent({ marketId: "weth-usdc-30", assetId: "usdc-a", amountUsd6: 1_200_000_000n }))
    expect(r.result.status).toBe("success")
    const all = sent.flat()
    const call = adapterCall(all)
    expect(call.functionName).toBe("borrow")
    expect(call.args).toEqual([7n, 1n, 1_200_000_000n, WALLET, 1_600n, 10n ** 18n, 3n])
    expect(onConfirmed).toHaveBeenCalledTimes(1)
  })

  it("repays everything owed with a buffer and repayAll when the amount covers the debt", async () => {
    const { deps, sent } = harness()
    const r = await executeBorrowOnChain(
      deps,
      intent({ actionType: "repay", debtPositionId: "debt:31337:7:1", amountUsd6: 1_200_000_000n }),
    )
    expect(r.result.status).toBe("success")
    const call = adapterCall(sent.flat())
    expect(call.functionName).toBe("repay")
    expect(call.args).toEqual([WALLET, 7n, 1n, 1_206_000_000n, true, 1_600n])
  })

  it("repays part of a debt without repayAll", async () => {
    const { deps, sent } = harness()
    await executeBorrowOnChain(deps, intent({ actionType: "repay", debtPositionId: "debt:31337:7:1", amountUsd6: 200_000_000n }))
    expect(adapterCall(sent.flat()).args).toEqual([WALLET, 7n, 1n, 200_000_000n, false, 1_600n])
  })

  it("fails without sending when the market has no account", async () => {
    const { deps, sent } = harness()
    const r = await executeBorrowOnChain(deps, intent({ marketId: "other", assetId: "usdc-a", amountUsd6: 1n }))
    expect(r.result.status).toBe("failed")
    expect(sent).toEqual([])
  })

  it("reports a reverted transaction and does not refresh", async () => {
    const { deps, onConfirmed } = harness({ reverted: true })
    const r = await executeBorrowOnChain(deps, intent({ marketId: "weth-usdc-30", assetId: "usdc-a", amountUsd6: 1_000_000n }))
    expect(r.result).toMatchObject({ status: "failed", error: "The transaction reverted." })
    expect(onConfirmed).not.toHaveBeenCalled()
  })
})
