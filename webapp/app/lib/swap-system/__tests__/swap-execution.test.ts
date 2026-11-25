import { decodeFunctionData, getAddress, parseAbi, type Address, type Hex } from "viem"
import { describe, expect, it, vi } from "vitest"
import { DEFAULT_FEE_RULES } from "@/convex/lib/fees"
import type { Call } from "@/app/lib/fees/fee-batch"
import { SWAP_ASSETS } from "@/app/lib/swap-system/catalog"
import type { SwapContracts } from "@/app/lib/swap-system/onchain-config"
import { encodePoolPath, type ExecutionRoute, type PoolToken } from "@/app/lib/swap-system/providers/onchain-pools"
import { unsupportedSwapQuote, type SwapQuote } from "@/app/lib/swap-system/quote-types"
import {
  SWAP_ROUTER_ABI,
  isUserRejection,
  minimumOut,
  sendSwap,
  sendSwapApproval,
  swapCalls,
  venueRouter,
  type SwapChain,
  type SwapExecutionDeps,
  type SwapWallet,
} from "@/app/lib/swap-system/swap-execution"

const A = (n: number) => getAddress(`0x${n.toString(16).padStart(40, "0")}`)
const USER = A(500)
const RECIPIENT = A(88)
const PARAMETER_STORE = A(77)
const USDC: PoolToken = { assetId: "usdc", symbol: "USDC", address: A(10), decimals: 6 }
const WETH: PoolToken = { assetId: "weth", symbol: "WETH", address: A(11), decimals: 18 }
const ETH: PoolToken = { ...WETH, assetId: "eth", symbol: "ETH", isNative: true }

const ethereum: SwapContracts = {
  chainId: 31337,
  nativeUsdFeed: A(9),
  lens: A(66),
  venues: [{ venue: "uniswap-v3", router: A(1), quoter: A(2) }],
  tokens: [
    { symbol: "USDC", address: USDC.address },
    { symbol: "WETH", address: WETH.address },
  ],
}

const ERC20 = parseAbi(["function transfer(address,uint256) returns (bool)", "function approve(address,uint256) returns (bool)"])
const decodeRouter = (data: Hex | undefined) => decodeFunctionData({ abi: SWAP_ROUTER_ABI, data: data! })
const decodeErc20 = (data: Hex | undefined) => decodeFunctionData({ abi: ERC20, data: data! })

// 1,000 USDC in: the 10 bps fee is 1 USDC, the route swaps 999 USDC.
const usdcRoute: ExecutionRoute = { venue: "uniswap-v3", route: { tokens: [USDC, WETH], poolKeys: [500] }, amountIn: 999_000_000n, amountOut: 333_000_000_000_000_000n }

function quote(over: Partial<SwapQuote> = {}): SwapQuote {
  const base = unsupportedSwapQuote({ walletId: "w", chainId: 31337, inputAssetId: "usdc", outputAssetId: "weth", inputAmount: 1_000, slippageBps: 50 })
  return { ...base, id: "q1", status: "valid", provider: "Uniswap v3", estimatedOutputAmount: 0.333, expiresAt: Date.now() + 120_000, ...over }
}

function fakeChain(allowance = 0n) {
  const chain: SwapChain = {
    readContract: vi.fn(async ({ functionName }) => (functionName === "allowance" ? allowance : PARAMETER_STORE)),
    latestBlockTimestamp: async () => 1_000n,
    batchChain: vi.fn(() => ({
      readFeeRecipient: async () => RECIPIENT,
      simulate: async (_account: Address, calls: readonly Call[]) => calls.map(() => true),
      callSucceeds: async () => true,
    })),
    waitForReceipt: async () => "success" as const,
  }
  return chain
}

function fakeWallet(atomic: boolean, sendCalls = vi.fn(async (_calls: readonly Call[]) => ({ id: "batch-1" }))) {
  const wallet: SwapWallet = {
    account: USER,
    supportsAtomicBatch: async () => atomic,
    sendCalls,
    sendTransaction: vi.fn(async () => "0xswap" as Hex),
    waitForCalls: async () => ({ status: "success", hash: "0xbatch" }),
  }
  return wallet
}

function deps(chain: SwapChain, wallet: SwapWallet | null, route: ExecutionRoute | undefined = usdcRoute, contracts = ethereum): SwapExecutionDeps {
  return { contracts, assets: SWAP_ASSETS, chain, wallet: async () => wallet, executionRoute: () => route, rules: DEFAULT_FEE_RULES, newId: () => "swap-1" }
}

describe("swap calls", () => {
  it("approves the exact route amount, then swaps on the quoted path with minOut and the deadline", () => {
    const calls = swapCalls({ route: usdcRoute, router: A(1), account: USER, minOut: 1n, deadline: 1_600n, approve: true, inputNative: false, outputNative: false })
    expect(calls).toHaveLength(2)
    expect(calls[0]!.to).toBe(USDC.address)
    expect(decodeErc20(calls[0]!.data)).toMatchObject({ functionName: "approve", args: [A(1), 999_000_000n] })
    expect(calls[1]!.to).toBe(A(1))
    expect(decodeRouter(calls[1]!.data)).toMatchObject({
      functionName: "exactInput",
      args: [{ path: encodePoolPath(usdcRoute.route, "uniswap-v3"), recipient: USER, deadline: 1_600n, amountIn: 999_000_000n, amountOutMinimum: 1n }],
    })
  })

  it("sends native ETH in as value, with no approval", () => {
    const route: ExecutionRoute = { ...usdcRoute, route: { tokens: [ETH, USDC], poolKeys: [500] }, amountIn: 999_000_000_000_000_000n }
    const calls = swapCalls({ route, router: A(1), account: USER, minOut: 1n, deadline: 1n, approve: true, inputNative: true, outputNative: false })
    expect(calls).toEqual([expect.objectContaining({ to: A(1), value: 999_000_000_000_000_000n })])
  })

  it("unwraps native ETH out to the user through the router", () => {
    const route: ExecutionRoute = { ...usdcRoute, route: { tokens: [USDC, ETH], poolKeys: [500] } }
    const [swap] = swapCalls({ route, router: A(1), account: USER, minOut: 7n, deadline: 1n, approve: false, inputNative: false, outputNative: true })
    const outer = decodeRouter(swap!.data)
    expect(outer.functionName).toBe("multicall")
    const [first, second] = (outer.args as [readonly Hex[]])[0]
    expect(decodeRouter(first).args).toEqual([expect.objectContaining({ recipient: A(1), amountOutMinimum: 7n })])
    expect(decodeRouter(second)).toMatchObject({ functionName: "unwrapWETH9", args: [7n, USER] })
  })

  it("on Base, encodes the Aero Slipstream path with the tick spacing and uses the manifest's Slipstream router", () => {
    const base: SwapContracts = { ...ethereum, chainId: 31338, venues: [{ venue: "slipstream", router: A(21), quoter: A(22) }] }
    const route: ExecutionRoute = { venue: "slipstream", route: { tokens: [USDC, WETH], poolKeys: [100] }, amountIn: 999_000_000n, amountOut: 1n }
    const router = venueRouter(base, "slipstream")!
    expect(router).toBe(A(21))
    const [swap] = swapCalls({ route, router, account: USER, minOut: 0n, deadline: 1n, approve: false, inputNative: false, outputNative: false })
    expect(swap!.to).toBe(A(21))
    const { path } = (decodeRouter(swap!.data).args as [{ path: Hex }])[0]
    // address (20 bytes) | int24 tick spacing 100 (0x000064) | address
    expect(path).toBe(`${USDC.address}000064${WETH.address.slice(2)}`.toLowerCase())
    expect(venueRouter(base, "uniswap-v3")).toBeNull()
  })

  it("takes the slippage off the quoted output, rounded down", () => {
    expect(minimumOut(1_000_001n, 50)).toBe(995_000n)
  })
})

describe("sending a swap", () => {
  it("batches the fee to the on-chain recipient first, then the approval and the swap, and confirms both together", async () => {
    const chain = fakeChain(0n)
    const wallet = fakeWallet(true)
    const record = await sendSwap(deps(chain, wallet), quote(), "w")

    expect(chain.batchChain).toHaveBeenCalledWith(PARAMETER_STORE)
    const calls = (wallet.sendCalls as ReturnType<typeof vi.fn>).mock.calls[0]![0] as Call[]
    expect(calls.map((c) => c.to)).toEqual([USDC.address, USDC.address, A(1)])
    expect(decodeErc20(calls[0]!.data)).toMatchObject({ functionName: "transfer", args: [RECIPIENT, 1_000_000n] })
    expect(decodeErc20(calls[1]!.data)).toMatchObject({ functionName: "approve", args: [A(1), 999_000_000n] })
    expect(decodeRouter(calls[2]!.data).args).toEqual([
      expect.objectContaining({ deadline: 1_600n, amountIn: 999_000_000n, amountOutMinimum: minimumOut(usdcRoute.amountOut, 50) }),
    ])
    expect(record).toMatchObject({ status: "confirmed", swapTransactionHash: "0xbatch", approvalTransactionHash: "0xbatch", outputAmount: 0.333 })
  })

  it("reports the sent swap to Convex, once for a batch and per hash without batching, and ignores a failing report", async () => {
    const recordIntent = vi.fn(async (_args: { chainId: number; wallet: string; txHash: Hex; kind: string }) => {})
    await sendSwap({ ...deps(fakeChain(0n), fakeWallet(true)), recordIntent }, quote(), "w")
    expect(recordIntent.mock.calls.map((c) => c[0])).toEqual([{ chainId: 31337, wallet: USER, txHash: "0xbatch", kind: "swap" }])

    recordIntent.mockClear()
    await sendSwap({ ...deps(fakeChain(999_000_000n), fakeWallet(false)), recordIntent }, quote(), "w", "0xapprove")
    expect(recordIntent.mock.calls.map((c) => c[0])).toEqual([{ chainId: 31337, wallet: USER, txHash: "0xswap", kind: "swap" }])

    const failing = vi.fn(async () => {
      throw new Error("down")
    })
    const record = await sendSwap({ ...deps(fakeChain(0n), fakeWallet(true)), recordIntent: failing }, quote(), "w")
    expect(record).toMatchObject({ status: "confirmed" })
  })

  it("skips the approval when the allowance covers the route amount", async () => {
    const wallet = fakeWallet(true)
    await sendSwap(deps(fakeChain(999_000_000n), wallet), quote(), "w")
    const calls = (wallet.sendCalls as ReturnType<typeof vi.fn>).mock.calls[0]![0] as Call[]
    expect(calls).toHaveLength(2)
  })

  it("without batching, sends the swap alone after its own approval, with no fee", async () => {
    const wallet = fakeWallet(false)
    const record = await sendSwap(deps(fakeChain(999_000_000n), wallet), quote(), "w", "0xapprove")
    expect(wallet.sendCalls).not.toHaveBeenCalled()
    expect(wallet.sendTransaction).toHaveBeenCalledTimes(1)
    expect((wallet.sendTransaction as ReturnType<typeof vi.fn>).mock.calls[0]![0]).toMatchObject({ to: A(1) })
    expect(record).toMatchObject({ status: "confirmed", swapTransactionHash: "0xswap", approvalTransactionHash: "0xapprove" })
  })

  it("never sends an expired quote", async () => {
    const wallet = fakeWallet(true)
    const record = await sendSwap(deps(fakeChain(), wallet), quote({ expiresAt: Date.now() - 1 }), "w")
    expect(record).toMatchObject({ status: "expired", failureReason: "Quote expired before submission." })
    expect(wallet.sendCalls).not.toHaveBeenCalled()
  })

  it("refuses a quote whose amount no longer matches its route", async () => {
    const record = await sendSwap(deps(fakeChain(), fakeWallet(true)), quote({ inputAmount: 2_000 }), "w")
    expect(record.status).toBe("failed")
  })

  it("reports a rejected batch as rejected", async () => {
    const sendCalls = vi.fn(async () => {
      throw Object.assign(new Error("denied"), { cause: { code: 4001 } })
    })
    const record = await sendSwap(deps(fakeChain(), fakeWallet(true, sendCalls)), quote(), "w")
    expect(record).toMatchObject({ status: "rejected", failureReason: "User rejected swap." })
    expect(isUserRejection({ name: "UserRejectedRequestError" })).toBe(true)
  })
})

describe("approving on its own", () => {
  it("approves the router for the exact route amount", async () => {
    const wallet = fakeWallet(false)
    const result = await sendSwapApproval(deps(fakeChain(), wallet), "usdc", 1_000, "uniswap-v3")
    const call = (wallet.sendTransaction as ReturnType<typeof vi.fn>).mock.calls[0]![0] as Call
    expect(call.to).toBe(USDC.address)
    expect(decodeErc20(call.data)).toMatchObject({ functionName: "approve", args: [A(1), 999_000_000n] })
    expect(result).toEqual({ status: "approval_confirmed", hash: "0xswap", failureReason: null })
  })
})
