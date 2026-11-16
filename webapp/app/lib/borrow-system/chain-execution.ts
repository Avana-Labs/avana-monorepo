import { encodeFunctionData, parseAbi, zeroAddress, type Address, type Hex } from "viem"
import { quoteFee } from "@/convex/lib/fees"
import { buildActionBatch, sendActionBatch, type BatchChain, type BatchWallet, type Call } from "@/app/lib/fees/fee-batch"
import { frontendFeeAmount, frontendFeeRules, type FeeAction, type FeeRules } from "@/app/lib/fees/front-end-fee"
import { isUserRejection } from "@/app/lib/swap-system/swap-execution"
import type { ChainBorrowRefs, PledgeableLp } from "@/app/lib/borrow-system/chain-refs"
import type { ChainDebtReserveRef } from "@/app/lib/borrow-system/chain-positions"
import type { ActionResult, TransactionActionType, TransactionIntent, TransactionPreview } from "@/app/lib/borrow-system/contracts"
import { lensAccountAbi } from "@/app/lib/borrow-system/lens-account-abi"
import type { BorrowSystemState } from "@/app/lib/borrow-system/model"
import { currentCollateralValueUsd6, currentDebtValueUsd6 } from "@/app/lib/borrow-system/model"

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
  "function pledge(uint256 marketId, (uint32 integrationId, bytes32 positionKey) position, uint256 deadline)",
  "function withdraw(uint256 marketId, (uint32 integrationId, bytes32 positionKey) position, uint256 units, uint256 deadline, uint256 minHealthFactor)",
])
const ERC20_ABI = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
])
/** The position manager's NFT approval: the market's LPVault takes the position on pledge. */
const ERC721_ABI = parseAbi(["function approve(address to, uint256 tokenId)"])
/** Records a proxy holds at most (the Adapter's 16-record limit). */
const MAX_RECORDS = 16n
/** A pledge may take every LP NFT of the market when they fall short of the amount by at most this much (bps), for a value that moved since it was shown. */
const PLEDGE_SHORTFALL_BPS = 100n

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
  /** The wallet's LP NFTs that a market accepts (for a pledge). */
  lps?(wallet: string): readonly PledgeableLp[]
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
  feeAction: FeeAction
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

/** `collateral:<chainId>:<marketId>`, as chainBorrowPositions names a collateral position. */
function parseCollateralId(id: string): { chainId: number; marketId: string } | null {
  const m = /^collateral:(\d+):(\d+)$/.exec(id)
  return m ? { chainId: Number(m[1]), marketId: m[2]! } : null
}

class ActionError extends Error {}

const NO_GAS = { gasUnits: 0n, baseFeeWei: 0n, priorityFeeWei: 0n, l1FeeWei: 0n, nativeUsd8: 0n } as const

/**
 * Whole LP positions covering `target`: the smallest one that covers it alone, else the largest first until they do.
 * Null when all of them together fall short.
 */
export function pickCovering<T>(items: readonly T[], value: (item: T) => bigint, target: bigint): T[] | null {
  const asc = [...items].sort((a, b) => (value(a) < value(b) ? -1 : value(a) > value(b) ? 1 : 0))
  const single = asc.find((item) => value(item) >= target)
  if (single) return [single]
  const picked: T[] = []
  let sum = 0n
  for (const item of asc.reverse()) {
    picked.push(item)
    sum += value(item)
    if (sum >= target) return picked
  }
  return null
}

/** The LP-value fee of a pledge or a collateral withdrawal, paid in the market's debt stablecoin (USDC first). */
function lpFee(
  deps: BorrowExecutionDeps,
  action: "pledge" | "withdrawCollateral",
  valueUsd6: bigint,
  refs: ChainBorrowRefs,
  chainId: number,
  spoke: string,
): { fee: bigint; feeToken: Address } {
  const stables = refs.debtReserves
    .filter((r) => r.chainId === chainId && r.spoke.toLowerCase() === spoke.toLowerCase() && r.priceUsd8)
    .sort((a, b) => Number(b.assetSlug.endsWith("usdc")) - Number(a.assetSlug.endsWith("usdc")))
  const stable = stables[0]
  if (!stable || valueUsd6 <= 0n) return { fee: 0n, feeToken: zeroAddress }
  const quote = quoteFee(deps.rules ?? frontendFeeRules(), {
    action,
    basis: { kind: "lpValue", valueUsd8: valueUsd6 * 100n, decimals: stable.decimals, priceUsd8: BigInt(stable.priceUsd8!) },
    gas: NO_GAS,
  })
  return { fee: quote.feeAmount, feeToken: stable.asset as Address }
}

const lensOf = (refs: ChainBorrowRefs, chainId: number) => refs.lenses.find((l) => l.chainId === chainId)?.lens as Address | undefined

/**
 * The LP NFTs a pledge of `amountUsd6` in the market `poolSlug` takes: only `positionKey`'s when given, else whole NFTs
 * covering the amount (pickCovering), else every NFT of the market when they fall short by at most
 * PLEDGE_SHORTFALL_BPS. Null when the wallet's NFTs cannot cover it.
 */
export function selectPledgeLps(
  lps: readonly PledgeableLp[],
  market: { chainId: number; marketId: string },
  amountUsd6: bigint,
  positionKey?: string,
): PledgeableLp[] | null {
  const owned = lps.filter((lp) => lp.chainId === market.chainId && lp.marketId === market.marketId)
  if (positionKey) {
    const one = owned.find((lp) => lp.positionKey.toLowerCase() === positionKey.toLowerCase())
    return one ? [one] : null
  }
  if (owned.length === 0) return null
  const total = owned.reduce((s, lp) => s + lp.valueUsd6, 0n)
  return (
    pickCovering(owned, (lp) => lp.valueUsd6, amountUsd6) ??
    (total * 10_000n >= amountUsd6 * (10_000n - PLEDGE_SHORTFALL_BPS) ? owned : null)
  )
}

/** The position key a pledge intent carries: the one LP NFT that covers the amount, if one does. */
export function pledgePositionKey(
  refs: ChainBorrowRefs | null,
  lps: readonly PledgeableLp[],
  poolSlug: string,
  amountUsd6: bigint,
): `0x${string}` | undefined {
  const market = refs?.markets?.find((m) => m.poolSlug === poolSlug)
  const picked = market && amountUsd6 > 0n ? selectPledgeLps(lps, market, amountUsd6) : null
  return picked?.length === 1 ? picked[0]!.positionKey : undefined
}

async function planPledge(deps: BorrowExecutionDeps, intent: TransactionIntent, refs: ChainBorrowRefs): Promise<PlannedAction> {
  const market = refs.markets?.find((m) => m.poolSlug === intent.marketId)
  const lens = market ? lensOf(refs, market.chainId) : undefined
  const chain = market ? deps.chain(market.chainId) : null
  if (!market || !lens || !chain) throw new ActionError("This market cannot take collateral here.")
  if (intent.amountUsd6 <= 0n) throw new ActionError("Enter an amount to pledge.")
  const lps = deps.lps?.(intent.walletId) ?? []
  if (!lps.some((lp) => lp.chainId === market.chainId && lp.marketId === market.marketId)) {
    throw new ActionError("Your wallet has no LP position for this market.")
  }
  const picked = selectPledgeLps(lps, market, intent.amountUsd6, intent.positionKey)
  if (!picked) throw new ActionError("Your LP positions in this market are worth less than this amount.")

  const adapter = (await chain.readContract({ address: lens, abi: LENS_ADDRESSES_ABI, functionName: "ADAPTER" })) as Address
  const deadline = (await chain.latestBlockTimestamp()) + ACTION_DEADLINE_SECONDS
  const calls: Call[] = picked.flatMap((lp) => [
    { to: lp.npm as Address, data: encodeFunctionData({ abi: ERC721_ABI, functionName: "approve", args: [lp.lpVault as Address, lp.tokenId] }) },
    {
      to: adapter,
      data: encodeFunctionData({
        abi: AAVE_ADAPTER_ABI,
        functionName: "pledge",
        args: [BigInt(market.marketId), { integrationId: lp.integrationId, positionKey: lp.positionKey }, deadline],
      }),
    },
  ])
  const value = picked.reduce((s, lp) => s + lp.valueUsd6, 0n)
  return { chainId: market.chainId, lens, feeAction: "pledge", calls, ...lpFee(deps, "pledge", value, refs, market.chainId, market.spoke) }
}

type RecordViewLike = { integrationId: number; positionKey: Hex; creditedAfterReconcile: bigint }

async function planWithdrawCollateral(deps: BorrowExecutionDeps, intent: TransactionIntent, refs: ChainBorrowRefs): Promise<PlannedAction> {
  const id = intent.positionId ? parseCollateralId(intent.positionId) : null
  const ref = id ? refs.accounts.find((a) => a.chainId === id.chainId && a.marketId === id.marketId) : undefined
  const lens = ref ? lensOf(refs, ref.chainId) : undefined
  const chain = ref ? deps.chain(ref.chainId) : null
  if (!ref || !lens || !chain) throw new ActionError("This collateral cannot be withdrawn here.")

  const records = (
    (await chain.readContract({
      address: lens,
      abi: lensAccountAbi,
      functionName: "getRecords",
      args: [ref.proxy as Address, 0n, MAX_RECORDS],
    })) as readonly RecordViewLike[]
  ).filter((r) => r.creditedAfterReconcile > 0n)
  const totalUnits = records.reduce((s, r) => s + r.creditedAfterReconcile, 0n)
  if (totalUnits === 0n) throw new ActionError("This account has no collateral to withdraw.")

  const state = deps.state()
  const position = state.accounts[intent.walletId]?.collateralPositions.find((p) => p.id === intent.positionId)
  const market = position ? state.markets[position.marketId] : undefined
  const valueUsd6 = position && market ? currentCollateralValueUsd6(position, market) : 0n
  const payload = intent.payload?.type === "removeCollateral" ? intent.payload : undefined
  const bps = BigInt(
    payload?.percentBps ?? (valueUsd6 > 0n && intent.amountUsd6 > 0n ? Number((intent.amountUsd6 * 10_000n) / valueUsd6) : 0),
  )
  if (bps <= 0n) throw new ActionError("Enter an amount to withdraw.")
  const picked =
    bps >= 10_000n ? records : (pickCovering(records, (r) => r.creditedAfterReconcile, (totalUnits * bps) / 10_000n) ?? records)

  const adapter = (await chain.readContract({ address: lens, abi: LENS_ADDRESSES_ABI, functionName: "ADAPTER" })) as Address
  const deadline = (await chain.latestBlockTimestamp()) + ACTION_DEADLINE_SECONDS
  const calls: Call[] = picked.map((r) => ({
    to: adapter,
    data: encodeFunctionData({
      abi: AAVE_ADAPTER_ABI,
      functionName: "withdraw",
      args: [
        BigInt(ref.marketId),
        { integrationId: r.integrationId, positionKey: r.positionKey },
        r.creditedAfterReconcile,
        deadline,
        BORROW_MIN_HEALTH_FACTOR,
      ],
    }),
  }))
  const units = picked.reduce((s, r) => s + r.creditedAfterReconcile, 0n)
  const value = (valueUsd6 * units) / totalUnits
  return {
    chainId: ref.chainId,
    lens,
    feeAction: "withdrawCollateral",
    calls,
    ...lpFee(deps, "withdrawCollateral", value, refs, ref.chainId, ref.spoke),
  }
}

/** The chain an action runs on, from the market or position it names. */
function targetChainId(intent: TransactionIntent, refs: ChainBorrowRefs): number | undefined {
  switch (intent.actionType) {
    case "borrow":
      return refs.accounts.find((a) => a.poolSlug === intent.marketId)?.chainId
    case "repay":
      return intent.debtPositionId ? parseDebtId(intent.debtPositionId)?.chainId : undefined
    case "deposit":
      return refs.markets?.find((m) => m.poolSlug === intent.marketId)?.chainId
    case "withdraw":
      return intent.positionId ? parseCollateralId(intent.positionId)?.chainId : undefined
    default:
      return undefined
  }
}

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

const SENT_ACTIONS: ReadonlySet<TransactionActionType> = new Set(["borrow", "repay", "deposit", "withdraw"])

/**
 * Sends a borrow, a repay, a pledge or a collateral withdrawal on the account's chain through the AaveAdapter, in the
 * fee batch (Q-409): the borrow with its fee last (paid from the borrowed tokens); the repay with its approval and its
 * fee first; the pledge with each LP NFT's approval to the market's LPVault and its fee (on the LP value, in the debt
 * stablecoin) first; the withdrawal of whole records with its fee last. A pledge takes whole LP NFTs and a withdrawal
 * whole records, so the amount sent covers the amount asked. Claim and liquidation are not sent from here. Resolves
 * with a failed result (never throws) for anything the chain or the wallet refuses.
 */
export async function executeBorrowOnChain(deps: BorrowExecutionDeps, intent: TransactionIntent): Promise<ActionResult> {
  if (!SENT_ACTIONS.has(intent.actionType)) {
    return result(deps, intent, "failed", "", { error: "This action is not available yet." })
  }
  const refs = deps.refs(intent.walletId)
  if (!refs) return result(deps, intent, "failed", "", { error: "Your accounts are still loading." })

  let chainId: number | undefined
  try {
    const target = targetChainId(intent, refs)
    if (target === undefined) throw new ActionError("This market is not open for this wallet.")
    chainId = target
    const wallet = await deps.wallet(target)
    if (!wallet) throw new ActionError("Connect a wallet on this network.")
    const plan =
      intent.actionType === "borrow"
        ? await planBorrow(deps, intent, wallet.account, refs)
        : intent.actionType === "repay"
          ? await planRepay(deps, intent, wallet.account, refs)
          : intent.actionType === "deposit"
            ? await planPledge(deps, intent, refs)
            : await planWithdrawCollateral(deps, intent, refs)
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
