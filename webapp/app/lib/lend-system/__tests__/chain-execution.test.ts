import { decodeFunctionData, getAddress, parseAbi, type Address } from "viem"
import { describe, expect, it, vi } from "vitest"
import type { BorrowChain, BorrowWallet } from "@/app/lib/borrow-system/chain-execution"
import { executeLendOnChain, LEND_SPOKE_ABI } from "@/app/lib/lend-system/chain-execution"
import type { LendHubAssetRef } from "@/app/lib/lend-system/chain-lend-refs"
import type { LendTransactionIntent } from "@/app/lib/lend-system/contracts"
import { emptyLendSystemState } from "@/app/lib/lend-system/market-hydration"
import { DEFAULT_FEE_RULES } from "@/convex/lib/fees"

const WALLET = getAddress("0x00000000000000000000000000000000000000c1")
const LENS = getAddress("0x00000000000000000000000000000000000000d1")
const USDC = getAddress("0x00000000000000000000000000000000000000e1")
const SPOKE_A = getAddress("0x00000000000000000000000000000000000000a1")
const SPOKE_B = getAddress("0x00000000000000000000000000000000000000a2")
const RECIPIENT = getAddress("0x00000000000000000000000000000000000000f1")

const asset: LendHubAssetRef = {
  chainId: 31337,
  slug: "ethereum-usdc",
  underlying: USDC,
  decimals: 6,
  priceUsd8: "100000000",
  lendReserves: [
    { spoke: SPOKE_A, reserveId: "1" },
    { spoke: SPOKE_B, reserveId: "2" },
  ],
}

function harness(supplied: Record<string, bigint> = {}) {
  const sent: { to: Address; data?: `0x${string}` }[][] = []
  const chain: BorrowChain = {
    readContract: vi.fn(async ({ address, functionName }: { address: Address; functionName: string }) => {
      if (functionName === "PARAMETER_STORE") return getAddress("0x00000000000000000000000000000000000000d3")
      if (functionName === "getUserSuppliedAssets") return supplied[address] ?? 0n
      throw new Error(`unexpected read ${functionName}`)
    }),
    latestBlockTimestamp: async () => 1_000n,
    batchChain: () => ({ readFeeRecipient: async () => RECIPIENT, callSucceeds: async () => true, simulate: async () => null }),
    waitForReceipt: async () => "success",
  }
  const wallet = {
    account: WALLET,
    supportsAtomicBatch: async () => true,
    sendCalls: async (calls: { to: Address; data?: `0x${string}` }[]) => {
      sent.push(calls)
      return { id: "batch-1" }
    },
    sendTransaction: async () => `0x${"ab".repeat(32)}`,
    waitForCalls: async () => ({ status: "success", hash: `0x${"cd".repeat(32)}` }),
  } as unknown as BorrowWallet
  const onConfirmed = vi.fn()
  const deps = {
    hubAssets: () => [asset],
    lens: () => LENS,
    chain: () => chain,
    wallet: async () => wallet,
    state: () => emptyLendSystemState(WALLET),
    onConfirmed,
    rules: DEFAULT_FEE_RULES,
    now: () => 5,
  }
  return { deps, sent, onConfirmed }
}

const intent = (over: Partial<LendTransactionIntent>): LendTransactionIntent => ({
  id: "intent-1",
  actionType: "deposit",
  walletId: WALLET,
  marketId: "ethereum-usdc",
  requestedAt: 0,
  simulated: false,
  ...over,
})

const decodeSpoke = (calls: { to: Address; data?: `0x${string}` }[]) =>
  calls.filter((c) => c.to === SPOKE_A || c.to === SPOKE_B).map((c) => ({ to: c.to, ...decodeFunctionData({ abi: LEND_SPOKE_ABI, data: c.data! }) }))

describe("executeLendOnChain", () => {
  it("supplies with the fee and approval first", async () => {
    const { deps, sent, onConfirmed } = harness()
    deps.hubAssets = () => [{ ...asset, lendReserves: [asset.lendReserves[0]!] }]
    const r = await executeLendOnChain(
      deps,
      intent({ payload: { type: "deposit", walletId: WALLET, marketId: "ethereum-usdc", depositAmount: 1_000 } }),
    )
    expect(r.receipt.status).toBe("success")
    const calls = sent.flat()
    expect(calls.map((c) => c.to)).toEqual([USDC, USDC, SPOKE_A])
    const fee = decodeFunctionData({ abi: parseAbi(["function transfer(address,uint256)"]), data: calls[0]!.data! })
    expect(fee.args).toEqual([RECIPIENT, 1_000_000n]) // 10 bps of 1,000 USDC
    const approve = decodeFunctionData({ abi: parseAbi(["function approve(address,uint256)"]), data: calls[1]!.data! })
    expect(approve.args).toEqual([SPOKE_A, 1_000_000_000n])
    expect(decodeSpoke(calls)[0]).toMatchObject({ functionName: "supply", args: [1n, 1_000_000_000n, WALLET] })
    expect(onConfirmed).toHaveBeenCalledTimes(1)
  })

  it("withdraws from the largest supply first, then the next, fee last", async () => {
    const { deps, sent } = harness({ [SPOKE_A]: 300_000_000n, [SPOKE_B]: 500_000_000n })
    await executeLendOnChain(
      deps,
      intent({
        actionType: "withdraw",
        payload: { type: "withdraw", walletId: WALLET, marketId: "ethereum-usdc", positionId: "p", withdrawAmount: 600 },
      }),
    )
    const calls = sent.flat()
    expect(decodeSpoke(calls)).toMatchObject([
      { to: SPOKE_B, functionName: "withdraw", args: [2n, 500_000_000n, WALLET] },
      { to: SPOKE_A, functionName: "withdraw", args: [1n, 100_000_000n, WALLET] },
    ])
    expect(calls.at(-1)!.to).toBe(USDC)
  })

  it("withdraws exactly what is supplied when asked for more", async () => {
    const { deps, sent } = harness({ [SPOKE_A]: 300_000_000n })
    await executeLendOnChain(
      deps,
      intent({
        actionType: "withdraw",
        payload: { type: "withdraw", walletId: WALLET, marketId: "ethereum-usdc", positionId: "p", withdrawAmount: 1_000 },
      }),
    )
    expect(decodeSpoke(sent.flat())).toMatchObject([{ to: SPOKE_A, args: [1n, 300_000_000n, WALLET] }])
  })

  it("supplies to the one open lend reserve and refuses to guess between several", async () => {
    const one = harness()
    one.deps.hubAssets = () => [{ ...asset, lendReserves: [{ ...asset.lendReserves[0]!, paused: true }, asset.lendReserves[1]!] }]
    await executeLendOnChain(
      one.deps,
      intent({ payload: { type: "deposit", walletId: WALLET, marketId: "ethereum-usdc", depositAmount: 1 } }),
    )
    expect(decodeSpoke(one.sent.flat())).toMatchObject([{ to: SPOKE_B, functionName: "supply" }])

    const two = harness()
    const r = await executeLendOnChain(
      two.deps,
      intent({ payload: { type: "deposit", walletId: WALLET, marketId: "ethereum-usdc", depositAmount: 1 } }),
    )
    expect(r.receipt.status).toBe("failed")
    expect(two.sent).toEqual([])
  })

  it("fails without sending for an unknown market", async () => {
    const { deps, sent } = harness()
    const r = await executeLendOnChain(
      deps,
      intent({ marketId: "other", payload: { type: "deposit", walletId: WALLET, marketId: "other", depositAmount: 1 } }),
    )
    expect(r.receipt).toMatchObject({ status: "failed", error: "This market is not available here." })
    expect(sent).toEqual([])
  })
})
