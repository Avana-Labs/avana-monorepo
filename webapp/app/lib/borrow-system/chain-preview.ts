import { parseAbi, type Address } from "viem"
import type { ChainBorrowRefs, PledgeableLp } from "@/app/lib/borrow-system/chain-refs"
import type { ChainBorrowAccountRef, ChainDebtReserveRef } from "@/app/lib/borrow-system/chain-positions"
import type {
  TransactionIntent,
  TransactionMetricsSnapshot,
  TransactionPreview,
  TransactionRiskLabel,
} from "@/app/lib/borrow-system/contracts"
import type { BorrowSystemState } from "@/app/lib/borrow-system/model"
import { currentCollateralValueUsd6, currentDebtValueUsd6 } from "@/app/lib/borrow-system/model"
import {
  ACTION_DEADLINE_SECONDS,
  pickCovering,
  selectPledgeLps,
  type BorrowChain,
} from "@/app/lib/borrow-system/chain-execution"
import { lensAccountAbi } from "@/app/lib/borrow-system/lens-account-abi"

/**
 * Previews of a borrow, a repay, a pledge or a collateral withdrawal from the Lens at the latest block
 * (`previewBorrowAfter`, `previewRepayAfter`, `previewBorrowMax`, `previewPledgeAfter`, `previewWithdrawAfter`), in the
 * shape the action pages already read. The account, reserve, market and Lens come from the same references the chain
 * executor uses (`chainBorrowRefs`); a pledge or a withdrawal previews the LP positions the executor would send, one Lens
 * call per position, combined (`combinePreviews`). Other actions answer "not available yet".
 */

export const LENS_PREVIEW_ABI = parseAbi([
  "struct ActionPreview { uint256 blockNumber; uint256 timestamp; address proxy; uint256 amount; uint256 healthFactorBefore; uint256 healthFactorAfter; uint256 liquidationPriceBefore; uint256 liquidationPriceAfter; uint256 collateralValueAfter; uint256 debtValueAfterRay; }",
  "function previewBorrowAfter(address wallet, uint256 marketId, uint256 debtReserveId, uint256 amount) view returns (ActionPreview)",
  "function previewRepayAfter(address wallet, uint256 marketId, uint256 debtReserveId, uint256 amount) view returns (ActionPreview)",
  "function previewBorrowMax(address wallet, uint256 marketId, uint256 debtReserveId, uint256 deadline) view returns (uint256)",
  "function previewPledgeAfter(address wallet, uint256 marketId, bytes32 positionKey) view returns (ActionPreview)",
  "function previewWithdrawAfter(address wallet, uint256 marketId, bytes32 positionKey) view returns (ActionPreview)",
])

export type ActionPreviewView = {
  amount: bigint
  healthFactorBefore: bigint
  healthFactorAfter: bigint
  collateralValueAfter: bigint
  debtValueAfterRay: bigint
}

export type BorrowPreviewDeps = {
  refs(wallet: string): ChainBorrowRefs | null
  /** The wallet's LP NFTs a market accepts (`pledgeableLps`), for the value of the NFT a pledge sends. */
  lps?(wallet: string): readonly PledgeableLp[]
  chain(chainId: number): Pick<BorrowChain, "readContract" | "latestBlockTimestamp"> | null
  state(): BorrowSystemState
}

export const PREVIEWS_UNAVAILABLE = "Previews are not available yet."
/** Records read per account, as the executor reads them. */
const MAX_RECORDS = 16n

const MAX_UINT = (1n << 256n) - 1n
const WAD = 1_000_000_000_000_000_000n
/**
 * Aave value units per micro-USD: `collateralValueAfter` is USD × 1e26, so dividing by 1e20 gives USD with 6 decimals
 * (the `…Usd6` amounts the pages read).
 */
const AAVE_VALUE_PER_USD6 = 100_000_000_000_000_000_000n
/** `debtValueAfterRay` is USD × 1e26 × RAY: dividing by 1e47 gives USD with 6 decimals. */
const AAVE_VALUE_RAY_PER_USD6 = AAVE_VALUE_PER_USD6 * 1_000_000_000_000_000_000_000_000_000n
/** Health factors below these are shown as danger and warning (WAD). */
const DANGER_HF = 1_100_000_000_000_000_000n
const WARNING_HF = 1_500_000_000_000_000_000n

const EMPTY: TransactionMetricsSnapshot = {
  collateralValueUsd6: 0n,
  borrowCapacityUsd6: 0n,
  availableBorrowCapacityUsd6: 0n,
  totalBorrowedUsd6: 0n,
  currentLtvWad: 0n,
  healthFactorWad: null,
}

function pow10(n: number): bigint {
  return BigInt(`1${"0".repeat(n)}`)
}

function priceUsd6(reserve: ChainDebtReserveRef): bigint {
  return reserve.priceUsd8 ? BigInt(reserve.priceUsd8) / 100n : 0n
}

function usd6ToUnits(usd6: bigint, reserve: ChainDebtReserveRef): bigint {
  const price = priceUsd6(reserve)
  return price > 0n ? (usd6 * pow10(reserve.decimals)) / price : 0n
}

function unitsToUsd6(units: bigint, reserve: ChainDebtReserveRef): bigint {
  return (units * priceUsd6(reserve)) / pow10(reserve.decimals)
}

/** `debt:<chainId>:<marketId>:<reserveId>`, as chainBorrowPositions names a debt. */
function parseDebtId(id: string): { chainId: number; marketId: string; reserveId: string } | null {
  const m = /^debt:(\d+):(\d+):(\d+)$/.exec(id)
  return m ? { chainId: Number(m[1]), marketId: m[2]!, reserveId: m[3]! } : null
}

/** `type(uint256).max` means no debt: null, which the pages show as ∞. */
function healthFactor(value: bigint): bigint | null {
  return value === MAX_UINT ? null : value
}

function riskLabel(hf: bigint | null): TransactionRiskLabel {
  if (hf === null) return "safe"
  if (hf < DANGER_HF) return "danger"
  if (hf < WARNING_HF) return "warning"
  return "safe"
}

function snapshot(
  collateralUsd6: bigint,
  debtUsd6: bigint,
  collateralFactorWad: bigint,
  availableUsd6: bigint,
  hf: bigint | null,
): TransactionMetricsSnapshot {
  const capacity = (collateralUsd6 * collateralFactorWad) / WAD
  return {
    collateralValueUsd6: collateralUsd6,
    borrowCapacityUsd6: capacity,
    availableBorrowCapacityUsd6: availableUsd6 > 0n ? availableUsd6 : 0n,
    totalBorrowedUsd6: debtUsd6,
    currentLtvWad: collateralUsd6 > 0n ? (debtUsd6 * WAD) / collateralUsd6 : 0n,
    healthFactorWad: hf,
  }
}

function blocked(intent: TransactionIntent, reason: string): TransactionPreview {
  return {
    intent,
    allowed: false,
    warnings: [],
    validationErrors: [reason],
    riskLabel: "safe",
    before: EMPTY,
    after: EMPTY,
  }
}

function revertReason(error: unknown): string {
  const e = error as { shortMessage?: string; message?: string }
  return e?.shortMessage ?? e?.message ?? "The Lens could not preview this action."
}

type Resolved = {
  account: ChainBorrowAccountRef
  reserve: ChainDebtReserveRef
  lens: Address
  chain: NonNullable<ReturnType<BorrowPreviewDeps["chain"]>>
}

function resolveBorrow(deps: BorrowPreviewDeps, intent: TransactionIntent, refs: ChainBorrowRefs): Resolved | string {
  const account = refs.accounts.find((a) => a.poolSlug === intent.marketId)
  if (!account) return "Pledge collateral in this market before borrowing."
  const reserve = refs.debtReserves.find(
    (r) =>
      r.chainId === account.chainId &&
      r.spoke.toLowerCase() === account.spoke.toLowerCase() &&
      r.assetSlug === intent.assetId,
  )
  const lens = refs.lenses.find((l) => l.chainId === account.chainId)?.lens as Address | undefined
  const chain = deps.chain(account.chainId)
  if (!reserve || !lens || !chain) return "This asset cannot be borrowed in this market."
  return { account, reserve, lens, chain }
}

function resolveRepay(deps: BorrowPreviewDeps, intent: TransactionIntent, refs: ChainBorrowRefs): Resolved | string {
  const id = intent.debtPositionId ? parseDebtId(intent.debtPositionId) : null
  const account = id ? refs.accounts.find((a) => a.chainId === id.chainId && a.marketId === id.marketId) : undefined
  const reserve =
    id && account
      ? refs.debtReserves.find(
          (r) =>
            r.chainId === id.chainId &&
            r.spoke.toLowerCase() === account.spoke.toLowerCase() &&
            r.reserveId === id.reserveId,
        )
      : undefined
  const lens = account
    ? (refs.lenses.find((l) => l.chainId === account.chainId)?.lens as Address | undefined)
    : undefined
  const chain = account ? deps.chain(account.chainId) : null
  if (!account || !reserve || !lens || !chain) return "This debt cannot be repaid here."
  return { account, reserve, lens, chain }
}

function collateralFactorWad(deps: BorrowPreviewDeps, marketSlug: string | null | undefined): bigint {
  return marketSlug ? (deps.state().markets[marketSlug]?.riskConfig.collateralFactorWad ?? 0n) : 0n
}

async function previewBorrow(deps: BorrowPreviewDeps, intent: TransactionIntent, refs: ChainBorrowRefs) {
  const r = resolveBorrow(deps, intent, refs)
  if (typeof r === "string") return blocked(intent, r)
  const units = usd6ToUnits(intent.amountUsd6, r.reserve)
  const latest = await r.chain.latestBlockTimestamp()
  const args = [intent.walletId as Address, BigInt(r.account.marketId), BigInt(r.reserve.reserveId)] as const
  const [after, max] = await Promise.all([
    r.chain.readContract({
      address: r.lens,
      abi: LENS_PREVIEW_ABI,
      functionName: "previewBorrowAfter",
      args: [...args, units],
    }) as Promise<ActionPreviewView>,
    r.chain.readContract({
      address: r.lens,
      abi: LENS_PREVIEW_ABI,
      functionName: "previewBorrowMax",
      args: [...args, latest + ACTION_DEADLINE_SECONDS],
    }) as Promise<bigint>,
  ])
  const cf = collateralFactorWad(deps, intent.marketId)
  const collateral = after.collateralValueAfter / AAVE_VALUE_PER_USD6
  const debtAfter = after.debtValueAfterRay / AAVE_VALUE_RAY_PER_USD6
  // The borrowed amount the Lens previewed, at the served price; collateral does not move on a borrow.
  const amountUsd6 = unitsToUsd6(after.amount, r.reserve)
  const debtBefore = debtAfter > amountUsd6 ? debtAfter - amountUsd6 : 0n
  const maxUsd6 = unitsToUsd6(max, r.reserve)
  const hfAfter = healthFactor(after.healthFactorAfter)
  const errors =
    units <= 0n ? ["Enter an amount to borrow."] : units > max ? ["Exceeds available borrowing power."] : []
  return {
    intent,
    allowed: errors.length === 0,
    warnings: [],
    validationErrors: errors,
    riskLabel: riskLabel(hfAfter),
    before: snapshot(collateral, debtBefore, cf, maxUsd6, healthFactor(after.healthFactorBefore)),
    after: snapshot(collateral, debtAfter, cf, maxUsd6 - amountUsd6, hfAfter),
  }
}

async function previewRepay(deps: BorrowPreviewDeps, intent: TransactionIntent, refs: ChainBorrowRefs) {
  const r = resolveRepay(deps, intent, refs)
  if (typeof r === "string") return blocked(intent, r)
  const position = deps.state().accounts[intent.walletId]?.debtPositions.find((d) => d.id === intent.debtPositionId)
  const owedUsd6 = position ? currentDebtValueUsd6(position) : 0n
  // At or above the debt repays all of it, as the executor sends it.
  const units = usd6ToUnits(owedUsd6 > 0n && intent.amountUsd6 >= owedUsd6 ? owedUsd6 : intent.amountUsd6, r.reserve)
  const after = (await r.chain.readContract({
    address: r.lens,
    abi: LENS_PREVIEW_ABI,
    functionName: "previewRepayAfter",
    args: [intent.walletId as Address, BigInt(r.account.marketId), BigInt(r.reserve.reserveId), units],
  })) as ActionPreviewView
  const cf = collateralFactorWad(deps, r.account.poolSlug)
  const collateral = after.collateralValueAfter / AAVE_VALUE_PER_USD6
  const debtAfter = after.debtValueAfterRay / AAVE_VALUE_RAY_PER_USD6
  // `amount` is the part Aave repays (an input at or above the debt repays all of it).
  const debtBefore = debtAfter + unitsToUsd6(after.amount, r.reserve)
  const capacity = (collateral * cf) / WAD
  const hfAfter = healthFactor(after.healthFactorAfter)
  const errors = units <= 0n ? ["Enter an amount to repay."] : owedUsd6 <= 0n ? ["There is no debt to repay."] : []
  return {
    intent,
    allowed: errors.length === 0,
    warnings: [],
    validationErrors: errors,
    riskLabel: riskLabel(hfAfter),
    before: snapshot(collateral, debtBefore, cf, capacity - debtBefore, healthFactor(after.healthFactorBefore)),
    after: snapshot(collateral, debtAfter, cf, capacity - debtAfter, hfAfter),
  }
}

/** `collateral:<chainId>:<marketId>`, as chainBorrowPositions names a collateral position. */
function parseCollateralId(id: string): { chainId: number; marketId: string } | null {
  const m = /^collateral:(\d+):(\d+)$/.exec(id)
  return m ? { chainId: Number(m[1]), marketId: m[2]! } : null
}

type RecordViewLike = { positionKey: `0x${string}`; creditedAfterReconcile: bigint }

/** The account's records with credited units, as the executor reads them. */
async function readRecords(chain: Resolved["chain"], lens: Address, proxy: string): Promise<readonly RecordViewLike[]> {
  const records = (await chain.readContract({
    address: lens,
    abi: lensAccountAbi,
    functionName: "getRecords",
    args: [proxy as Address, 0n, MAX_RECORDS],
  })) as readonly RecordViewLike[]
  return records.filter((r) => r.creditedAfterReconcile > 0n)
}

/**
 * The single-position previews of one action (`previewPledgeAfter` or `previewWithdrawAfter` per LP position, each
 * against the account as it is now) combined into the preview of the whole action, with the collateral value before
 * (USD 6 decimals). `unitsBefore` is the account's credited units, `sign` 1 for a pledge and −1 for a withdrawal.
 *
 * An account (one PositionProxy per market) has one collateral reserve, the vault token (LensAccountMath), so its
 * collateral value and health factor are linear in its units at a fixed collateral factor and debt: one preview's
 * after-values, scaled by the units after the whole action over the units after that preview, are the action's. The
 * reference preview carries the collateral factor the action ends with (the Lens refreshes it on a pledge that turns
 * the collateral on and on a withdrawal), which `HF_before × C_after / C_before` would miss. The liquidation price
 * (`liqBefore × units_before / units_after`) is not part of the page's snapshot, so it is not combined.
 *
 * Rounding: the Lens floors each value and the scaling floors again, and the account's Hub assets can differ from its
 * credited units by the Hub's share rounding, so the result can differ from a single preview of the same action by a
 * few base units. Null when no preview leaves units to scale from (a withdrawal of the whole account in one record).
 */
export function combinePreviews(
  previews: readonly ActionPreviewView[],
  unitsBefore: bigint,
  sign: 1n | -1n,
): { view: ActionPreviewView; collateralBeforeUsd6: bigint } | null {
  const ref = previews.find((p) => unitsBefore + sign * p.amount > 0n)
  if (!ref) return null
  const moved = previews.reduce((sum, p) => sum + p.amount, 0n)
  const refUnits = unitsBefore + sign * ref.amount
  const left = unitsBefore + sign * moved
  const unitsAfter = left > 0n ? left : 0n
  const scale = (x: bigint) => (x * unitsAfter) / refUnits
  return {
    view: {
      amount: moved,
      healthFactorBefore: ref.healthFactorBefore,
      // No debt stays no debt (∞).
      healthFactorAfter: ref.healthFactorAfter === MAX_UINT ? MAX_UINT : scale(ref.healthFactorAfter),
      collateralValueAfter: scale(ref.collateralValueAfter),
      debtValueAfterRay: ref.debtValueAfterRay,
    },
    collateralBeforeUsd6: (ref.collateralValueAfter * unitsBefore) / refUnits / AAVE_VALUE_PER_USD6,
  }
}

/** A pledge or withdrawal preview: debt does not move, the collateral before is given. */
function fromLens(
  intent: TransactionIntent,
  preview: ActionPreviewView,
  cf: bigint,
  collateralBefore: bigint,
  errors: string[],
): TransactionPreview {
  const collateral = preview.collateralValueAfter / AAVE_VALUE_PER_USD6
  const debt = preview.debtValueAfterRay / AAVE_VALUE_RAY_PER_USD6
  const hfAfter = healthFactor(preview.healthFactorAfter)
  return {
    intent,
    allowed: errors.length === 0,
    warnings: [],
    validationErrors: errors,
    riskLabel: riskLabel(hfAfter),
    before: snapshot(
      collateralBefore,
      debt,
      cf,
      (collateralBefore * cf) / WAD - debt,
      healthFactor(preview.healthFactorBefore),
    ),
    after: snapshot(collateral, debt, cf, (collateral * cf) / WAD - debt, hfAfter),
  }
}

async function previewPledge(deps: BorrowPreviewDeps, intent: TransactionIntent, refs: ChainBorrowRefs) {
  const market = refs.markets?.find((m) => m.poolSlug === intent.marketId)
  const lens = market ? (refs.lenses.find((l) => l.chainId === market.chainId)?.lens as Address | undefined) : undefined
  const chain = market ? deps.chain(market.chainId) : null
  if (!market || !lens || !chain) return blocked(intent, "This market cannot take collateral here.")
  if (intent.amountUsd6 <= 0n) return blocked(intent, "Enter an amount to pledge.")
  // The NFTs the executor pledges: the intent's one, or whole NFTs covering the amount (the executor's messages).
  let keys: readonly `0x${string}`[]
  if (intent.positionKey) {
    keys = [intent.positionKey]
  } else {
    const lps = deps.lps?.(intent.walletId) ?? []
    if (!lps.some((lp) => lp.chainId === market.chainId && lp.marketId === market.marketId)) {
      return blocked(intent, "Your wallet has no LP position for this market.")
    }
    const picked = selectPledgeLps(lps, market, intent.amountUsd6)
    if (!picked) return blocked(intent, "Your LP positions in this market are worth less than this amount.")
    keys = picked.map((lp) => lp.positionKey)
  }
  const account = refs.accounts.find((a) => a.chainId === market.chainId && a.marketId === market.marketId)
  const [records, previews] = await Promise.all([
    account ? readRecords(chain, lens, account.proxy) : Promise.resolve([]),
    Promise.all(
      keys.map(
        (key) =>
          chain.readContract({
            address: lens,
            abi: LENS_PREVIEW_ABI,
            functionName: "previewPledgeAfter",
            args: [intent.walletId as Address, BigInt(market.marketId), key],
          }) as Promise<ActionPreviewView>,
      ),
    ),
  ])
  const unitsBefore = records.reduce((sum, r) => sum + r.creditedAfterReconcile, 0n)
  const combined = combinePreviews(previews, unitsBefore, 1n)
  const cf = collateralFactorWad(deps, intent.marketId)
  // Null only when nothing is held and nothing is pledged: no collateral before.
  return fromLens(intent, combined?.view ?? previews[0]!, cf, combined?.collateralBeforeUsd6 ?? 0n, [])
}

async function previewWithdraw(deps: BorrowPreviewDeps, intent: TransactionIntent, refs: ChainBorrowRefs) {
  const id = intent.positionId ? parseCollateralId(intent.positionId) : null
  const account = id ? refs.accounts.find((a) => a.chainId === id.chainId && a.marketId === id.marketId) : undefined
  const lens = account
    ? (refs.lenses.find((l) => l.chainId === account.chainId)?.lens as Address | undefined)
    : undefined
  const chain = account ? deps.chain(account.chainId) : null
  if (!account || !lens || !chain) return blocked(intent, "This collateral cannot be withdrawn here.")
  const records = await readRecords(chain, lens, account.proxy)
  const totalUnits = records.reduce((sum, r) => sum + r.creditedAfterReconcile, 0n)
  if (totalUnits === 0n) return blocked(intent, "This account has no collateral to withdraw.")

  // The records the executor withdraws: all of them, or the fewest whole records covering the share asked for.
  const state = deps.state()
  const position = state.accounts[intent.walletId]?.collateralPositions.find((p) => p.id === intent.positionId)
  const market = position ? state.markets[position.marketId] : undefined
  const valueUsd6 = position && market ? currentCollateralValueUsd6(position, market) : 0n
  const payload = intent.payload?.type === "removeCollateral" ? intent.payload : undefined
  const bps = BigInt(
    payload?.percentBps ??
      (valueUsd6 > 0n && intent.amountUsd6 > 0n ? Number((intent.amountUsd6 * 10_000n) / valueUsd6) : 0),
  )
  if (bps <= 0n) return blocked(intent, "Enter an amount to withdraw.")
  const picked =
    bps >= 10_000n
      ? records
      : (pickCovering(records, (r) => r.creditedAfterReconcile, (totalUnits * bps) / 10_000n) ?? records)

  const previews = await Promise.all(
    picked.map(
      (record) =>
        chain.readContract({
          address: lens,
          abi: LENS_PREVIEW_ABI,
          functionName: "previewWithdrawAfter",
          args: [intent.walletId as Address, BigInt(account.marketId), record.positionKey],
        }) as Promise<ActionPreviewView>,
    ),
  )
  const combined = combinePreviews(previews, totalUnits, -1n)
  // Null only for the whole account in one record: nothing is left, the collateral before is the position's value.
  const view = combined?.view ?? previews[0]!
  const before = combined?.collateralBeforeUsd6 ?? valueUsd6
  const hfAfter = healthFactor(view.healthFactorAfter)
  // The executor sends a withdrawal with Aave's health factor floor (1.0): below it the chain refuses it.
  const errors =
    hfAfter !== null && hfAfter < WAD ? ["This withdrawal would leave the position below a health factor of 1."] : []
  return fromLens(intent, view, collateralFactorWad(deps, account.poolSlug), before, errors)
}

/**
 * The preview of an action at the latest block. Never throws: a Lens revert, a missing reference or an action without
 * a chain preview yet comes back not allowed, with the reason in `validationErrors`.
 */
export async function previewBorrowOnChain(
  deps: BorrowPreviewDeps,
  intent: TransactionIntent,
): Promise<TransactionPreview> {
  const refs = deps.refs(intent.walletId)
  if (!refs) return blocked(intent, "Your positions are still loading.")
  try {
    if (intent.actionType === "borrow") return await previewBorrow(deps, intent, refs)
    if (intent.actionType === "repay") return await previewRepay(deps, intent, refs)
    if (intent.actionType === "deposit") return await previewPledge(deps, intent, refs)
    if (intent.actionType === "withdraw") return await previewWithdraw(deps, intent, refs)
    return blocked(intent, PREVIEWS_UNAVAILABLE)
  } catch (error) {
    return blocked(intent, revertReason(error))
  }
}
