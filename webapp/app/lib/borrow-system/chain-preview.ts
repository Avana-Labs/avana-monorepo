import { parseAbi, type Address } from "viem"
import type { ChainBorrowRefs } from "@/app/lib/borrow-system/chain-refs"
import type { ChainBorrowAccountRef, ChainDebtReserveRef } from "@/app/lib/borrow-system/chain-positions"
import type {
  TransactionIntent,
  TransactionMetricsSnapshot,
  TransactionPreview,
  TransactionRiskLabel,
} from "@/app/lib/borrow-system/contracts"
import type { BorrowSystemState } from "@/app/lib/borrow-system/model"
import { currentDebtValueUsd6 } from "@/app/lib/borrow-system/model"
import { ACTION_DEADLINE_SECONDS, type BorrowChain } from "@/app/lib/borrow-system/chain-execution"

/**
 * Previews of a borrow or a repay from the Lens at the latest block (`previewBorrowAfter`, `previewRepayAfter`,
 * `previewBorrowMax`), in the shape the action pages already read. The account, reserve and Lens come from the same
 * references the chain executor uses (`chainBorrowRefs`). Other actions answer "not available yet".
 */

export const LENS_PREVIEW_ABI = parseAbi([
  "struct ActionPreview { uint256 blockNumber; uint256 timestamp; address proxy; uint256 amount; uint256 healthFactorBefore; uint256 healthFactorAfter; uint256 liquidationPriceBefore; uint256 liquidationPriceAfter; uint256 collateralValueAfter; uint256 debtValueAfterRay; }",
  "function previewBorrowAfter(address wallet, uint256 marketId, uint256 debtReserveId, uint256 amount) view returns (ActionPreview)",
  "function previewRepayAfter(address wallet, uint256 marketId, uint256 debtReserveId, uint256 amount) view returns (ActionPreview)",
  "function previewBorrowMax(address wallet, uint256 marketId, uint256 debtReserveId, uint256 deadline) view returns (uint256)",
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
  chain(chainId: number): Pick<BorrowChain, "readContract" | "latestBlockTimestamp"> | null
  state(): BorrowSystemState
}

export const PREVIEWS_UNAVAILABLE = "Previews are not available yet."

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
    return blocked(intent, PREVIEWS_UNAVAILABLE)
  } catch (error) {
    return blocked(intent, revertReason(error))
  }
}
