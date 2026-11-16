import { decodeFunctionData, getAddress, parseAbi, type Address } from "viem"
import { describe, expect, it, vi } from "vitest"
import {
  AAVE_ADAPTER_ABI,
  executeBorrowOnChain,
  pickCovering,
  pledgePositionKey,
  type BorrowChain,
  type BorrowWallet,
} from "@/app/lib/borrow-system/chain-execution"
import type { ChainBorrowRefs, PledgeableLp } from "@/app/lib/borrow-system/chain-refs"
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
const NPM = getAddress("0x00000000000000000000000000000000000000e2")
const VAULT = getAddress("0x00000000000000000000000000000000000000e3")
const KEY_A = `0x${"0".repeat(62)}0a` as const
const KEY_B = `0x${"0".repeat(62)}0b` as const

const refs: ChainBorrowRefs = {
  wallet: WALLET,
  lenses: [{ chainId: 31337, lens: LENS }],
  accounts: [{ chainId: 31337, marketId: "7", spoke: SPOKE, proxy: PROXY, poolSlug: "weth-usdc-30" }],
  markets: [
    { chainId: 31337, marketId: "7", spoke: SPOKE, poolSlug: "weth-usdc-30" },
    { chainId: 31337, marketId: "8", spoke: SPOKE, poolSlug: "wbtc-usdc-30" },
  ],
  debtReserves: [{ chainId: 31337, spoke: SPOKE, reserveId: "1", asset: USDC, assetSlug: "usdc-a", decimals: 6, priceUsd8: "100000000" }],
}

const lp = (tokenId: bigint, valueUsd6: bigint, positionKey: `0x${string}` = KEY_A): PledgeableLp => ({
  chainId: 31337,
  marketId: "8",
  integrationId: 1,
  positionKey,
  npm: NPM,
  tokenId,
  lpVault: VAULT,
  valueUsd6,
})

const RECORDS = [
  { recordId: 1n, integrationId: 1, positionKey: KEY_A, creditedAfterReconcile: 100n },
  { recordId: 2n, integrationId: 1, positionKey: KEY_B, creditedAfterReconcile: 300n },
  { recordId: 3n, integrationId: 1, positionKey: KEY_B, creditedAfterReconcile: 0n },
]

function harness(opts: { atomic?: boolean; reverted?: boolean; lps?: PledgeableLp[] } = {}) {
  const sent: { to: Address; data?: `0x${string}` }[][] = []
  const chain: BorrowChain = {
    readContract: vi.fn(async ({ functionName }: { functionName: string }) => {
      if (functionName === "ADAPTER") return ADAPTER
      if (functionName === "PARAMETER_STORE") return STORE
      if (functionName === "borrowNonce") return 3n
      if (functionName === "getRecords") return RECORDS
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
    lps: () => opts.lps ?? [],
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

  it("pledges the one LP NFT that covers the amount, fee first, after approving the market's LPVault", async () => {
    const { deps, sent } = harness({ atomic: true, lps: [lp(11n, 30_000_000_000n), lp(12n, 50_000_000_000n, KEY_B)] })
    const r = await executeBorrowOnChain(deps, intent({ actionType: "deposit", marketId: "wbtc-usdc-30", amountUsd6: 40_000_000_000n }))
    expect(r.result.status).toBe("success")
    const all = sent.flat()
    expect(all.map((c) => c.to)).toEqual([USDC, NPM, ADAPTER])
    const fee = decodeFunctionData({ abi: parseAbi(["function transfer(address,uint256)"]), data: all[0]!.data! })
    expect(fee.args[1]).toBe(50_000_000n) // 10 bps of the $50,000 pledged, in USDC
    const approve = decodeFunctionData({ abi: parseAbi(["function approve(address,uint256)"]), data: all[1]!.data! })
    expect(approve.args).toEqual([VAULT, 12n])
    const call = adapterCall(all)
    expect(call.functionName).toBe("pledge")
    expect(call.args).toEqual([8n, { integrationId: 1, positionKey: KEY_B }, 1_600n])
  })

  it("pledges only the LP NFT the intent names", async () => {
    const { deps, sent } = harness({ lps: [lp(11n, 30_000_000_000n), lp(12n, 50_000_000_000n, KEY_B)] })
    await executeBorrowOnChain(
      deps,
      intent({ actionType: "deposit", marketId: "wbtc-usdc-30", amountUsd6: 40_000_000_000n, positionKey: KEY_A }),
    )
    expect(adapterCall(sent.flat()).args).toEqual([8n, { integrationId: 1, positionKey: KEY_A }, 1_600n])
  })

  it("names the one LP NFT covering a pledge on the intent, and none when several are needed", () => {
    const lps = [lp(11n, 30_000_000_000n), lp(12n, 50_000_000_000n, KEY_B)]
    expect(pledgePositionKey(refs, lps, "wbtc-usdc-30", 40_000_000_000n)).toBe(KEY_B)
    expect(pledgePositionKey(refs, lps, "wbtc-usdc-30", 70_000_000_000n)).toBeUndefined()
    expect(pledgePositionKey(null, lps, "wbtc-usdc-30", 1n)).toBeUndefined()
  })

  it("fails without sending when the wallet has no LP NFT for the market", async () => {
    const { deps, sent } = harness({ lps: [{ ...lp(11n, 1n), marketId: "7" }] })
    const r = await executeBorrowOnChain(deps, intent({ actionType: "deposit", marketId: "wbtc-usdc-30", amountUsd6: 1n }))
    expect(r.result).toMatchObject({ status: "failed", error: "Your wallet has no LP position for this market." })
    expect(sent).toEqual([])
  })

  it("withdraws the record covering the percentage, with its units after reconcile", async () => {
    const { deps, sent } = harness()
    const r = await executeBorrowOnChain(
      deps,
      intent({
        actionType: "withdraw",
        positionId: "collateral:31337:7",
        payload: { type: "removeCollateral", walletId: WALLET, positionId: "collateral:31337:7", percentBps: 5_000 },
      }),
    )
    expect(r.result.status).toBe("success")
    const calls = sent.flat().filter((c) => c.to === ADAPTER).map((c) => decodeFunctionData({ abi: AAVE_ADAPTER_ABI, data: c.data! }))
    expect(calls).toHaveLength(1)
    expect(calls[0]!.functionName).toBe("withdraw")
    expect(calls[0]!.args).toEqual([7n, { integrationId: 1, positionKey: KEY_B }, 300n, 1_600n, 10n ** 18n])
  })

  it("withdraws every credited record at 100%", async () => {
    const { deps, sent } = harness()
    await executeBorrowOnChain(
      deps,
      intent({
        actionType: "withdraw",
        positionId: "collateral:31337:7",
        payload: { type: "removeCollateral", walletId: WALLET, positionId: "collateral:31337:7", percentBps: 10_000 },
      }),
    )
    const units = sent
      .flat()
      .filter((c) => c.to === ADAPTER)
      .map((c) => decodeFunctionData({ abi: AAVE_ADAPTER_ABI, data: c.data! }).args[2])
    expect(units).toEqual([100n, 300n])
  })

  it("reports a reverted transaction and does not refresh", async () => {
    const { deps, onConfirmed } = harness({ reverted: true })
    const r = await executeBorrowOnChain(deps, intent({ marketId: "weth-usdc-30", assetId: "usdc-a", amountUsd6: 1_000_000n }))
    expect(r.result).toMatchObject({ status: "failed", error: "The transaction reverted." })
    expect(onConfirmed).not.toHaveBeenCalled()
  })
})

describe("pickCovering", () => {
  const v = (x: bigint) => x
  it("takes the smallest single item that covers the target", () => {
    expect(pickCovering([5n, 50n, 30n], v, 25n)).toEqual([30n])
  })
  it("takes the largest first until the target is covered", () => {
    expect(pickCovering([5n, 10n, 20n], v, 28n)).toEqual([20n, 10n])
  })
  it("is null when everything together falls short", () => {
    expect(pickCovering([5n, 10n], v, 16n)).toBeNull()
  })
})
