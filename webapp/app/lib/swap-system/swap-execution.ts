import { encodeFunctionData, maxUint256, parseAbi, parseUnits, type Address, type Hex } from "viem"
import { buildActionBatch, sendActionBatch, type BatchChain, type BatchWallet, type Call } from "@/app/lib/fees/fee-batch"
import { frontendFeeAmount, frontendFeeRules, type FeeRules } from "@/app/lib/fees/front-end-fee"
import type { SwapAsset } from "./contracts"
import type { SwapContracts } from "./onchain-config"
import { encodePoolPath, type ExecutionRoute } from "./providers/onchain-pools"
import { isQuoteUsable, type SwapQuote, type SwapTransactionRecord, type SwapTransactionStatus } from "./quote-types"

/**
 * Sends a quoted swap on the chain's own pools, in the batch every app action uses (Q-409, `fee-batch.ts`):
 *
 * 1. the front-end fee to the ParameterStore's `feeRecipient` (read on chain through the Lens), first, since the user
 *    pays with the input;
 * 2. `approve(router, amountIn)` for the exact amount, only when the allowance is short (never for native ETH);
 * 3. the venue router's `exactInput` on the quoted route, with `minOut` from the quote and the slippage, and a deadline
 *    600 s after the latest block (the chain's clock, not the wall clock). Native ETH in is sent as value; native ETH
 *    out is `multicall([exactInput to the router, unwrapWETH9(minOut, user)])`.
 *
 * A wallet without atomic batches approves first (`sendSwapApproval`), then swaps, as two transactions without the
 * fee. An expired quote is never sent.
 */

export const SWAP_DEADLINE_SECONDS = 600n

/** The SwapRouter of Uniswap v3 and of Aero Slipstream (same `exactInput` params; the path differs). */
export const SWAP_ROUTER_ABI = parseAbi([
  "struct ExactInputParams { bytes path; address recipient; uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; }",
  "function exactInput(ExactInputParams params) payable returns (uint256 amountOut)",
  "function unwrapWETH9(uint256 amountMinimum, address recipient) payable",
  "function multicall(bytes[] data) payable returns (bytes[] results)",
])
const ERC20_ABI = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
])
export const LENS_PARAMETER_STORE_ABI = parseAbi(["function PARAMETER_STORE() view returns (address)"])

/** The least output the swap accepts: the quoted output less the slippage, rounded down. */
export function minimumOut(amountOut: bigint, slippageBps: number): bigint {
  return (amountOut * BigInt(10_000 - slippageBps)) / 10_000n
}

/** The router that sends a venue's swaps, from the chain's manifest. */
export function venueRouter(contracts: SwapContracts, venue: ExecutionRoute["venue"]): Address | null {
  const router = contracts.venues.find((v) => v.venue === venue)?.router
  return router ? (router as Address) : null
}

/** The approve call (when asked) and the swap call of a quoted route. */
export function swapCalls(args: {
  route: ExecutionRoute
  router: Address
  account: Address
  minOut: bigint
  deadline: bigint
  approve: boolean
  inputNative: boolean
  outputNative: boolean
}): Call[] {
  const { route, router, account, minOut, deadline } = args
  const path = encodePoolPath(route.route, route.venue)
  const exactInput = (recipient: Address) =>
    encodeFunctionData({
      abi: SWAP_ROUTER_ABI,
      functionName: "exactInput",
      args: [{ path, recipient, deadline, amountIn: route.amountIn, amountOutMinimum: minOut }],
    })
  const data = args.outputNative
    ? encodeFunctionData({
        abi: SWAP_ROUTER_ABI,
        functionName: "multicall",
        args: [[exactInput(router), encodeFunctionData({ abi: SWAP_ROUTER_ABI, functionName: "unwrapWETH9", args: [minOut, account] })]],
      })
    : exactInput(account)
  const swap: Call = { to: router, data, ...(args.inputNative ? { value: route.amountIn } : {}) }
  if (!args.approve || args.inputNative) return [swap]
  const approve: Call = {
    to: route.route.tokens[0]!.address,
    data: encodeFunctionData({ abi: ERC20_ABI, functionName: "approve", args: [router, route.amountIn] }),
  }
  return [approve, swap]
}

/** What sending reads from the swap chain. */
export type SwapChain = {
  readContract(args: { address: Address; abi: readonly unknown[]; functionName: string; args?: readonly unknown[] }): Promise<unknown>
  latestBlockTimestamp(): Promise<bigint>
  batchChain(parameterStore: Address): BatchChain
  waitForReceipt(hash: Hex): Promise<"success" | "reverted">
}

/** The connected wallet on the swap chain. */
export type SwapWallet = BatchWallet & {
  account: Address
  /** Waits for an EIP-5792 batch; its transaction hash when the wallet reports one. */
  waitForCalls(id: string): Promise<{ status: "success" | "failure"; hash: Hex | null }>
}

export type SwapExecutionDeps = {
  contracts: SwapContracts
  assets: readonly SwapAsset[]
  chain: SwapChain
  wallet(): Promise<SwapWallet | null>
  executionRoute(quoteId: string): ExecutionRoute | undefined
  rules?: FeeRules
  now?: () => number
  newId?: (prefix: string) => string
}

export type SwapApprovalResult = {
  status: "approval_confirmed" | "rejected" | "failed"
  hash: string | null
  failureReason: string | null
}

function toUnits(amount: number, decimals: number): bigint {
  if (!Number.isFinite(amount) || amount <= 0) return 0n
  return parseUnits(amount.toFixed(Math.min(decimals, 18)), decimals)
}

/** The route amount of a typed input: the input less the front-end fee, as the quote priced it. */
export function routeAmountIn(amount: number, asset: SwapAsset, rules: FeeRules = frontendFeeRules()): { units: bigint; fee: bigint; amountIn: bigint } {
  const units = toUnits(amount, asset.decimals)
  const fee = frontendFeeAmount("swap", units, asset.decimals, rules)
  return { units, fee, amountIn: units - fee }
}

/** A wallet's rejection, anywhere in the error's cause chain (EIP-1193 code 4001). */
export function isUserRejection(error: unknown): boolean {
  for (let e = error as { code?: unknown; name?: unknown; cause?: unknown } | undefined, depth = 0; e && depth < 8; depth++) {
    if (e.code === 4001 || e.name === "UserRejectedRequestError") return true
    e = e.cause as typeof e
  }
  return false
}

/** The router's allowance from the account for the input token; unlimited for native ETH. */
export async function readSwapAllowance(chain: SwapChain, account: Address, token: Address, router: Address, native: boolean): Promise<bigint> {
  if (native) return maxUint256
  return (await chain.readContract({ address: token, abi: ERC20_ABI, functionName: "allowance", args: [account, router] })) as bigint
}

function defaultId(prefix: string) {
  return `${prefix}-${Math.random().toString(36).slice(2, 10)}`
}

function swapRecord(
  quote: SwapQuote,
  walletId: string,
  id: string,
  now: number,
  status: SwapTransactionStatus,
  extra: Partial<SwapTransactionRecord> = {},
): SwapTransactionRecord {
  return {
    id,
    walletId,
    inputAssetId: quote.inputAssetId,
    outputAssetId: quote.outputAssetId,
    inputAmount: quote.inputAmount,
    outputAmount: status === "confirmed" ? quote.estimatedOutputAmount : 0,
    minimumOutputAmount: quote.minimumOutputAmount,
    quoteId: quote.id,
    provider: quote.provider,
    exchangeRate: quote.exchangeRate,
    priceImpactPct: quote.priceImpactPct,
    slippageBps: quote.slippageBps,
    networkFeeUsd: quote.networkFeeUsd,
    route: [...quote.route],
    status,
    createdAt: now,
    ...extra,
  }
}

/** Approves the router for a wallet that cannot batch: the exact route amount, one transaction. */
export async function sendSwapApproval(
  deps: SwapExecutionDeps,
  assetId: string,
  amount: number,
  venue: ExecutionRoute["venue"],
): Promise<SwapApprovalResult> {
  const asset = deps.assets.find((a) => a.id === assetId)
  if (asset?.isNative) return { status: "approval_confirmed", hash: null, failureReason: null }
  const token = deps.contracts.tokens.find((t) => t.symbol.toUpperCase() === asset?.symbol.toUpperCase())?.address as Address | undefined
  const router = venueRouter(deps.contracts, venue)
  const wallet = await deps.wallet()
  if (!asset || !token || !router || !wallet) return { status: "failed", hash: null, failureReason: "Approval failed." }
  const { amountIn } = routeAmountIn(amount, asset, deps.rules)
  try {
    const hash = await wallet.sendTransaction({
      to: token,
      data: encodeFunctionData({ abi: ERC20_ABI, functionName: "approve", args: [router, amountIn] }),
    })
    if ((await deps.chain.waitForReceipt(hash)) !== "success") return { status: "failed", hash, failureReason: "Approval failed." }
    return { status: "approval_confirmed", hash, failureReason: null }
  } catch (error) {
    if (isUserRejection(error)) return { status: "rejected", hash: null, failureReason: "User rejected approval." }
    return { status: "failed", hash: null, failureReason: "Approval failed." }
  }
}

/**
 * Sends a quoted swap. With an atomic batch the approval (when needed) rides in the same batch as the fee and the
 * swap, so both confirm with it and share its hash; without one the swap goes alone, after `sendSwapApproval`.
 */
export async function sendSwap(deps: SwapExecutionDeps, quote: SwapQuote, walletId: string, approvalHash?: string): Promise<SwapTransactionRecord> {
  const now = deps.now?.() ?? Date.now()
  const id = (deps.newId ?? defaultId)("swap")
  const record = (status: SwapTransactionStatus, extra?: Partial<SwapTransactionRecord>) => swapRecord(quote, walletId, id, now, status, extra)

  if (!isQuoteUsable(quote, now)) return record("expired", { failureReason: "Quote expired before submission." })

  const route = deps.executionRoute(quote.id)
  const input = deps.assets.find((a) => a.id === quote.inputAssetId)
  const output = deps.assets.find((a) => a.id === quote.outputAssetId)
  const router = route ? venueRouter(deps.contracts, route.venue) : null
  const lens = deps.contracts.lens as Address | undefined
  if (!route || !input || !output || !router || !lens) return record("failed", { failureReason: "This quote can no longer be sent." })
  const { fee, amountIn } = routeAmountIn(quote.inputAmount, input, deps.rules)
  if (amountIn !== route.amountIn) return record("failed", { failureReason: "This quote can no longer be sent." })

  const wallet = await deps.wallet()
  if (!wallet) return record("failed", { failureReason: "Connect a wallet to swap." })

  const tokenIn = route.route.tokens[0]!.address
  try {
    const atomic = await wallet.supportsAtomicBatch()
    const [allowance, latest, parameterStore] = await Promise.all([
      readSwapAllowance(deps.chain, wallet.account, tokenIn, router, Boolean(input.isNative)),
      deps.chain.latestBlockTimestamp(),
      deps.chain.readContract({ address: lens, abi: LENS_PARAMETER_STORE_ABI, functionName: "PARAMETER_STORE" }) as Promise<Address>,
    ])
    const approveInBatch = atomic && allowance < route.amountIn
    const calls = swapCalls({
      route,
      router,
      account: wallet.account,
      minOut: minimumOut(route.amountOut, quote.slippageBps),
      deadline: latest + SWAP_DEADLINE_SECONDS,
      approve: approveInBatch,
      inputNative: Boolean(input.isNative),
      outputNative: Boolean(output.isNative),
    })
    const batch = await buildActionBatch({
      action: "swap",
      account: wallet.account,
      calls,
      quote: { feeAmount: fee },
      feeToken: input.isNative ? "native" : tokenIn,
      chain: deps.chain.batchChain(parameterStore),
    })
    const sent = await sendActionBatch("swap", batch, wallet)

    let hash: Hex | null = null
    let ok = true
    if (sent.kind === "batch") {
      const result = await wallet.waitForCalls(sent.id)
      ok = result.status === "success"
      hash = result.hash
    } else {
      for (const h of sent.hashes) {
        hash = h
        if ((await deps.chain.waitForReceipt(h)) !== "success") {
          ok = false
          break
        }
      }
    }
    const hashes = {
      ...(hash ? { swapTransactionHash: hash } : {}),
      ...(approveInBatch && hash ? { approvalTransactionHash: hash } : approvalHash ? { approvalTransactionHash: approvalHash } : {}),
    }
    if (!ok) return record("failed", { ...hashes, failureReason: "Swap transaction reverted." })
    return record("confirmed", { ...hashes, confirmedAt: deps.now?.() ?? Date.now() })
  } catch (error) {
    if (isUserRejection(error)) return record("rejected", { failureReason: "User rejected swap." })
    return record("failed", { failureReason: "Swap transaction failed." })
  }
}
