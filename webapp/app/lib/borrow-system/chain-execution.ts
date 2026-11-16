import { encodeFunctionData, parseAbi, type Address, type Hex } from "viem"
import { buildActionBatch, sendActionBatch, type BatchChain, type BatchWallet, type Call } from "@/app/lib/fees/fee-batch"
import { frontendFeeAmount, frontendFeeRules, type FeeRules } from "@/app/lib/fees/front-end-fee"
import { isUserRejection } from "@/app/lib/swap-system/swap-execution"
import type { ChainBorrowRefs } from "@/app/lib/borrow-system/chain-refs"
import type { ChainDebtReserveRef } from "@/app/lib/borrow-system/chain-positions"
import type { ActionResult, TransactionActionType, TransactionIntent, TransactionPreview } from "@/app/lib/borrow-system/contracts"
import type { BorrowSystemState } from "@/app/lib/borrow-system/model"
import { currentDebtValueUsd6 } from "@/app/lib/borrow-system/model"

/** How long a sent action stays valid on chain. */
export const ACTION_DEADLINE_SECONDS = 600n
/** The lowest health factor a borrow may leave (WAD): the protocol's own floor. */
export const BORROW_MIN_HEALTH_FACTOR = 10n ** 18n
/** A full repay may spend up to this much over the debt read at send time (bps), for interest accrued until it lands. */
export const REPAY_ALL_BUFFER_BPS = 50n

export const LENS_ADDRESSES_ABI = parseAbi([
  "function ADAPTER() view returns (address)",
  "function PARAMETER_STORE() view returns (address)",
])
export const AAVE_ADAPTER_ABI = parseAbi([
  "function proxyOf(address wallet, uint256 marketId) view returns (address)",
  "function borrowNonce(address proxy) view returns (uint256)",
  "function borrow(uint256 marketId, uint256 debtReserveId, uint256 amount, address receiver, uint256 deadline, uint256 minHealthFactor, uint256 expectedNonce)",
  "function repay(address borrower, uint256 marketId, uint256 debtReserveId, uint256 maxRepaySpend, bool repayAll, uint256 deadline)",
])
const ERC20_ABI = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
])

/** What sending reads from the account's chain. */
export type BorrowChain = {
  readContract(args: { address: Address; abi: readonly unknown[]; functionName: string; args?: readonly unknown[] }): Promise<unknown>
  latestBlockTimestamp(): Promise<bigint>
  batchChain(parameterStore: Address): BatchChain
  waitForReceipt(hash: Hex): Promise<"success" | "reverted">
}

/** The connected wallet on the account's chain. */
export type BorrowWallet = BatchWallet & {
  account: Address
  waitForCalls(id: string): Promise<{ status: "success" | "failure"; hash: Hex | null }>
}

export type BorrowExecutionDeps = {
  refs(wallet: string): ChainBorrowRefs | null
  chain(chainId: number): BorrowChain | null
  wallet(chainId: number): Promise<BorrowWallet | null>
  state(): BorrowSystemState
  onConfirmed?(): void
  rules?: FeeRules
  now?: () => number
}

/** A chain call of one action: where it runs, its calls, and the fee leg it pays. */
type PlannedAction = {
  chainId: number
  lens: Address
  feeAction: "borrow" | "repay"
  calls: Call[]
  fee: bigint
  feeToken: Address
}

const usd6ToUnits = (usd6: bigint, reserve: ChainDebtReserveRef): bigint => {
  const priceUsd6 = reserve.priceUsd8 ? BigInt(reserve.priceUsd8) / 100n : 0n
  if (priceUsd6 <= 0n) return 0n
  return (usd6 * 10n ** BigInt(reserve.decimals)) / priceUsd6
}

/** `debt:<chainId>:<marketId>:<reserveId>`, as chainBorrowPositions names a debt. */
function parseDebtId(id: string): { chainId: number; marketId: string; reserveId: string } | null {
  const m = /^debt:(\d+):(\d+):(\d+)$/.exec(id)
  return m ? { chainId: Number(m[1]), marketId: m[2]!, reserveId: m[3]! } : null
}

class ActionError extends Error {}

async function planBorrow(deps: BorrowExecutionDeps, intent: TransactionIntent, account: Address, refs: ChainBorrowRefs): Promise<PlannedAction> {
  const ref = refs.accounts.find((a) => a.poolSlug === intent.marketId)
  if (!ref) throw new ActionError("Pledge collateral in this market before borrowing.")
  const reserve = refs.debtReserves.find(
    (r) => r.chainId === ref.chainId && r.spoke.toLowerCase() === ref.spoke.toLowerCase() && r.assetSlug === intent.assetId,
  )
  const lens = refs.lenses.find((l) => l.chainId === ref.chainId)?.lens as Address | undefined
  const chain = deps.chain(ref.chainId)
  if (!reserve || !lens || !chain) throw new ActionError("This asset cannot be borrowed in this market.")
  const amount = usd6ToUnits(intent.amountUsd6, reserve)
  if (amount <= 0n) throw new ActionError("Enter an amount to borrow.")
  const adapter = (await chain.readContract({ address: lens, abi: LENS_ADDRESSES_ABI, functionName: "ADAPTER" })) as Address
  const [nonce, latest] = await Promise.all([
    chain.readContract({ address: adapter, abi: AAVE_ADAPTER_ABI, functionName: "borrowNonce", args: [ref.proxy as Address] }) as Promise<bigint>,
    chain.latestBlockTimestamp(),
  ])
  const data = encodeFunctionData({
    abi: AAVE_ADAPTER_ABI,
    functionName: "borrow",
    args: [BigInt(ref.marketId), BigInt(reserve.reserveId), amount, account, latest + ACTION_DEADLINE_SECONDS, BORROW_MIN_HEALTH_FACTOR, nonce],
  })
  const priceUsd8 = reserve.priceUsd8 ? BigInt(reserve.priceUsd8) : 0n
  return {
    chainId: ref.chainId,
    lens,
    feeAction: "borrow",
    calls: [{ to: adapter, data }],
    fee: frontendFeeAmount("borrow", amount, reserve.decimals, deps.rules ?? frontendFeeRules(), priceUsd8),
    feeToken: reserve.asset as Address,
  }
}

async function planRepay(deps: BorrowExecutionDeps, intent: TransactionIntent, account: Address, refs: ChainBorrowRefs): Promise<PlannedAction> {
  const id = intent.debtPositionId ? parseDebtId(intent.debtPositionId) : null
  const ref = id ? refs.accounts.find((a) => a.chainId === id.chainId && a.marketId === id.marketId) : undefined
  const reserve =
    id && ref
      ? refs.debtReserves.find(
          (r) => r.chainId === id.chainId && r.spoke.toLowerCase() === ref.spoke.toLowerCase() && r.reserveId === id.reserveId,
        )
      : undefined
  const lens = ref ? (refs.lenses.find((l) => l.chainId === ref.chainId)?.lens as Address | undefined) : undefined
  const chain = ref ? deps.chain(ref.chainId) : null
  if (!id || !ref || !reserve || !lens || !chain) throw new ActionError("This debt cannot be repaid here.")

  const position = deps.state().accounts[intent.walletId]?.debtPositions.find((d) => d.id === intent.debtPositionId)
  const owedUsd6 = position ? currentDebtValueUsd6(position) : 0n
  const repayAll = owedUsd6 > 0n && intent.amountUsd6 >= owedUsd6
  const base = usd6ToUnits(repayAll ? owedUsd6 : intent.amountUsd6, reserve)
  if (base <= 0n) throw new ActionError("Enter an amount to repay.")
  const spend = repayAll ? base + (base * REPAY_ALL_BUFFER_BPS) / 10_000n : base

  const adapter = (await chain.readContract({ address: lens, abi: LENS_ADDRESSES_ABI, functionName: "ADAPTER" })) as Address
  const latest = await chain.latestBlockTimestamp()
  const calls: Call[] = [
    { to: reserve.asset as Address, data: encodeFunctionData({ abi: ERC20_ABI, functionName: "approve", args: [adapter, spend] }) },
    {
      to: adapter,
      data: encodeFunctionData({
        abi: AAVE_ADAPTER_ABI,
        functionName: "repay",
        args: [account, BigInt(ref.marketId), BigInt(reserve.reserveId), spend, repayAll, latest + ACTION_DEADLINE_SECONDS],
      }),
    },
  ]
  const priceUsd8 = reserve.priceUsd8 ? BigInt(reserve.priceUsd8) : 0n
  return {
    chainId: ref.chainId,
    lens,
    feeAction: "repay",
    calls,
    fee: frontendFeeAmount("repay", base, reserve.decimals, deps.rules ?? frontendFeeRules(), priceUsd8),
    feeToken: reserve.asset as Address,
  }
}

const NO_METRICS = {
  collateralValueUsd6: 0n,
  borrowCapacityUsd6: 0n,
  availableBorrowCapacityUsd6: 0n,
  totalBorrowedUsd6: 0n,
  currentLtvWad: 0n,
  healthFactorWad: null,
}

function result(
  deps: BorrowExecutionDeps,
  intent: TransactionIntent,
  status: "success" | "failed",
  hash: string,
  extra: { chainId?: number; error?: string } = {},
): ActionResult {
  const timestamp = deps.now?.() ?? Date.now()
  const actionType: TransactionActionType = intent.actionType
  const preview: TransactionPreview = {
    intent,
    allowed: status === "success",
    warnings: [],
    validationErrors: extra.error ? [extra.error] : [],
    riskLabel: "safe",
    before: NO_METRICS,
    after: NO_METRICS,
  }
  const receipt = { id: intent.id, hash, status, actionType, simulated: false, timestamp, ...extra }
  return {
    preview,
    receipt,
    result: receipt,
    historyItem: {
      id: intent.id,
      intentId: intent.id,
      walletId: intent.walletId,
      ...(intent.marketId ? { marketId: intent.marketId } : {}),
      ...(intent.assetId ? { assetId: intent.assetId } : {}),
      kind: actionType,
      status,
      requestedAmountUsd6: intent.amountUsd6,
      executedAmountUsd6: status === "success" ? intent.amountUsd6 : 0n,
      simulated: false,
      timestamp,
      hash,
    },
    state: deps.state(),
  }
}

/**
 * Sends a borrow or a repay on the account's chain through the AaveAdapter, in the fee batch (Q-409): the borrow with its
 * fee last (paid from the borrowed tokens), the repay with its approval and its fee first. Other actions are not
 * sent from here yet. Resolves with a failed result (never throws) for anything the chain or the wallet refuses.
 */
export async function executeBorrowOnChain(deps: BorrowExecutionDeps, intent: TransactionIntent): Promise<ActionResult> {
  if (intent.actionType !== "borrow" && intent.actionType !== "repay") {
    return result(deps, intent, "failed", "", { error: "This action is not available yet." })
  }
  const refs = deps.refs(intent.walletId)
  if (!refs) return result(deps, intent, "failed", "", { error: "Your accounts are still loading." })

  let chainId: number | undefined
  try {
    const target =
      intent.actionType === "borrow"
        ? refs.accounts.find((a) => a.poolSlug === intent.marketId)?.chainId
        : (intent.debtPositionId ? parseDebtId(intent.debtPositionId)?.chainId : undefined)
    if (target === undefined) throw new ActionError("This market is not open for this wallet.")
    chainId = target
    const wallet = await deps.wallet(target)
    if (!wallet) throw new ActionError("Connect a wallet on this network.")
    const plan =
      intent.actionType === "borrow"
        ? await planBorrow(deps, intent, wallet.account, refs)
        : await planRepay(deps, intent, wallet.account, refs)
    const chain = deps.chain(plan.chainId)!
    const parameterStore = (await chain.readContract({ address: plan.lens, abi: LENS_ADDRESSES_ABI, functionName: "PARAMETER_STORE" })) as Address
    const batch = await buildActionBatch({
      action: plan.feeAction,
      account: wallet.account,
      calls: plan.calls,
      quote: { feeAmount: plan.fee },
      feeToken: plan.feeToken,
      chain: chain.batchChain(parameterStore),
    })
    const sent = await sendActionBatch(plan.feeAction, batch, wallet)

    let hash: Hex | null = null
    let ok = true
    if (sent.kind === "batch") {
      const r = await wallet.waitForCalls(sent.id)
      ok = r.status === "success"
      hash = r.hash
    } else {
      for (const h of sent.hashes) {
        hash = h
        if ((await chain.waitForReceipt(h)) !== "success") {
          ok = false
          break
        }
      }
    }
    if (!ok) return result(deps, intent, "failed", hash ?? "", { chainId, error: "The transaction reverted." })
    deps.onConfirmed?.()
    return result(deps, intent, "success", hash ?? "", { chainId })
  } catch (error) {
    if (isUserRejection(error)) return result(deps, intent, "failed", "", { ...(chainId ? { chainId } : {}), error: "You rejected the transaction." })
    const message = error instanceof ActionError ? error.message : "The transaction failed."
    return result(deps, intent, "failed", "", { ...(chainId ? { chainId } : {}), error: message })
  }
}
