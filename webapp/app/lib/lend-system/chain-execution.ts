import { encodeFunctionData, maxUint256, parseAbi, parseUnits, type Address, type Hex } from "viem"
import { buildActionBatch, sendActionBatch, type Call } from "@/app/lib/fees/fee-batch"
import { frontendFeeAmount, frontendFeeRules, type FeeRules } from "@/app/lib/fees/front-end-fee"
import { isUserRejection } from "@/app/lib/swap-system/swap-execution"
import { LENS_ADDRESSES_ABI, type BorrowChain, type BorrowWallet } from "@/app/lib/borrow-system/chain-execution"
import type { LendHubAssetRef } from "@/app/lib/lend-system/chain-lend-refs"
import type { LendActionResult, LendTransactionIntent, LendTransactionPreview } from "@/app/lib/lend-system/contracts"
import type { LendSystemState } from "@/app/lib/lend-system/model"

export const LEND_SPOKE_ABI = parseAbi([
  "function supply(uint256 reserveId, uint256 amount, address onBehalfOf) returns (uint256, uint256)",
  "function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf) returns (uint256, uint256)",
  "function getUserSuppliedAssets(uint256 reserveId, address user) view returns (uint256)",
])
const ERC20_APPROVE_ABI = parseAbi(["function approve(address spender, uint256 amount) returns (bool)"])

export type LendExecutionDeps = {
  hubAssets(): readonly LendHubAssetRef[] | null
  /** The Lens of a chain (for the ParameterStore's fee recipient). */
  lens(walletId: string, chainId: number): string | undefined
  chain(chainId: number): BorrowChain | null
  wallet(chainId: number): Promise<BorrowWallet | null>
  state(): LendSystemState
  onConfirmed?(): void
  rules?: FeeRules
  now?: () => number
}

type PlannedLend = { feeAction: "supply" | "withdraw"; calls: Call[]; amount: bigint }

class ActionError extends Error {}

/** A whole-token amount in base units (float input from the action page). */
function toUnits(amount: number, decimals: number): bigint {
  if (!Number.isFinite(amount) || amount <= 0) return 0n
  return parseUnits(amount.toFixed(decimals), decimals)
}

/** The one lend reserve a supply goes to: the asset's reserve that is neither paused nor frozen; an error when none or several are. */
function supplyReserve(asset: LendHubAssetRef) {
  const open = asset.lendReserves.filter((r) => !r.paused && !r.frozen)
  if (open.length === 0) throw new ActionError("This asset cannot be supplied right now.")
  if (open.length > 1) throw new ActionError("This asset has more than one Lend Spoke; supply is not available here yet.")
  return open[0]!
}

function planSupply(asset: LendHubAssetRef, account: Address, amount: bigint): PlannedLend {
  const reserve = supplyReserve(asset)
  const spoke = reserve.spoke as Address
  return {
    feeAction: "supply",
    amount,
    calls: [
      { to: asset.underlying as Address, data: encodeFunctionData({ abi: ERC20_APPROVE_ABI, functionName: "approve", args: [spoke, amount] }) },
      {
        to: spoke,
        data: encodeFunctionData({ abi: LEND_SPOKE_ABI, functionName: "supply", args: [BigInt(reserve.reserveId), amount, account] }),
      },
    ],
  }
}

/**
 * Withdraws `requested` from the asset's lend reserves, largest supply first, each at most what it holds now. A reserve
 * the request empties is withdrawn with the maximum amount, which the Spoke caps to the whole supply at execution, so
 * interest accrued after the read leaves no dust; the fee stays sized on the amount read.
 */
async function planWithdraw(chain: BorrowChain, asset: LendHubAssetRef, account: Address, requested: bigint): Promise<PlannedLend> {
  const held = await Promise.all(
    asset.lendReserves.map(async (r) => ({
      ...r,
      supplied: (await chain.readContract({
        address: r.spoke as Address,
        abi: LEND_SPOKE_ABI,
        functionName: "getUserSuppliedAssets",
        args: [BigInt(r.reserveId), account],
      })) as bigint,
    })),
  )
  const order = held.filter((r) => r.supplied > 0n).sort((a, b) => (a.supplied > b.supplied ? -1 : a.supplied < b.supplied ? 1 : 0))
  if (order.length === 0) throw new ActionError("Nothing is supplied to withdraw.")
  const calls: Call[] = []
  let left = requested
  for (const r of order) {
    if (left <= 0n) break
    const take = r.supplied < left ? r.supplied : left
    calls.push({
      to: r.spoke as Address,
      data: encodeFunctionData({ abi: LEND_SPOKE_ABI, functionName: "withdraw", args: [BigInt(r.reserveId), take === r.supplied ? maxUint256 : take, account] }),
    })
    left -= take
  }
  return { feeAction: "withdraw", calls, amount: requested - (left > 0n ? left : 0n) }
}

const NO_METRICS = {
  suppliedAmount: 0,
  suppliedValueUsd: 0,
  principalAmount: 0,
  interestEarned: 0,
  rewardsEarnedUsd: 0,
  totalEarnedUsd: 0,
  currentApy: 0,
}

function result(
  deps: LendExecutionDeps,
  intent: LendTransactionIntent,
  status: "success" | "failed",
  hash: string,
  error?: string,
): LendActionResult {
  const timestamp = deps.now?.() ?? Date.now()
  const actionType = intent.actionType
  const preview: LendTransactionPreview = {
    intent,
    allowed: status === "success",
    warnings: [],
    validationErrors: error ? [error] : [],
    before: NO_METRICS,
    after: NO_METRICS,
  }
  const payload = intent.payload
  const amount = payload?.type === "deposit" ? payload.depositAmount : payload?.type === "withdraw" ? payload.withdrawAmount : 0
  const state = deps.state()
  return {
    preview,
    receipt: { id: intent.id, hash, status, actionType, simulated: false, timestamp, ...(error ? { error } : {}) },
    historyItem: {
      id: intent.id,
      intentId: intent.id,
      walletId: intent.walletId,
      marketId: intent.marketId,
      ...(intent.positionId ? { positionId: intent.positionId } : {}),
      kind: actionType,
      status,
      asset: state.markets[intent.marketId]?.asset.symbol ?? "",
      amount: status === "success" ? amount : 0,
      simulated: false,
      timestamp,
      hash,
    },
    state,
  }
}

/**
 * Sends a Lend supply or withdrawal to the asset's Lend Spoke in the fee batch (Q-409): the supply, to the asset's one
 * open lend reserve on its chain, with its approval and its fee (10 bps of the amount, in the supplied token) first; the withdrawal, from the asset's lend reserves
 * largest first, with its fee last. Claim is not sent from here. Resolves with a failed result (never throws) for
 * anything the chain or the wallet refuses.
 */
export async function executeLendOnChain(deps: LendExecutionDeps, intent: LendTransactionIntent): Promise<LendActionResult> {
  if (intent.actionType !== "deposit" && intent.actionType !== "withdraw") {
    return result(deps, intent, "failed", "", "This action is not available yet.")
  }
  const assets = deps.hubAssets()
  if (!assets) return result(deps, intent, "failed", "", "Markets are still loading.")
  try {
    const chainId = deps.state().markets[intent.marketId]?.chainId
    const matches = assets.filter((a) => a.slug === intent.marketId && (chainId === undefined || a.chainId === chainId))
    if (matches.length > 1) throw new ActionError("This market is ambiguous here.")
    const asset = matches[0]
    const chain = asset ? deps.chain(asset.chainId) : null
    const lens = asset ? (deps.lens(intent.walletId, asset.chainId) as Address | undefined) : undefined
    if (!asset || !chain || !lens) throw new ActionError("This market is not available here.")
    const payload = intent.payload
    const requested = toUnits(
      payload?.type === "deposit" ? payload.depositAmount : payload?.type === "withdraw" ? payload.withdrawAmount : 0,
      asset.decimals,
    )
    if (requested <= 0n) throw new ActionError("Enter an amount.")
    const wallet = await deps.wallet(asset.chainId)
    if (!wallet) throw new ActionError("Connect a wallet on this network.")

    const plan =
      intent.actionType === "deposit"
        ? planSupply(asset, wallet.account, requested)
        : await planWithdraw(chain, asset, wallet.account, requested)
    const parameterStore = (await chain.readContract({ address: lens, abi: LENS_ADDRESSES_ABI, functionName: "PARAMETER_STORE" })) as Address
    const fee = frontendFeeAmount(plan.feeAction, plan.amount, asset.decimals, deps.rules ?? frontendFeeRules(), BigInt(asset.priceUsd8))
    const batch = await buildActionBatch({
      action: plan.feeAction,
      account: wallet.account,
      calls: plan.calls,
      quote: { feeAmount: fee },
      feeToken: asset.underlying as Address,
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
    if (!ok) return result(deps, intent, "failed", hash ?? "", "The transaction reverted.")
    deps.onConfirmed?.()
    return result(deps, intent, "success", hash ?? "")
  } catch (error) {
    if (isUserRejection(error)) return result(deps, intent, "failed", "", "You rejected the transaction.")
    return result(deps, intent, "failed", "", error instanceof ActionError ? error.message : "The transaction failed.")
  }
}
