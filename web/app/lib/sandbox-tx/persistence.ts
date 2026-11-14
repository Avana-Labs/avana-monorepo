/**
 * Maps a sandbox `TransactionHistoryItem` onto Convex `recordTransaction` args: the Credit
 * Engine simulates, Convex persists. Money crosses the wire as a decimal usd6 string per the
 * schema encoding contract. Pure, so the mapping is unit-tested without a Convex client.
 */

import type { SandboxActionResult, TransactionHistoryItem } from "@/app/lib/borrow-system/contracts"
import type { LendSandboxActionResult } from "@/app/lib/lend-system/contracts"
import type { MultiplySandboxActionResult } from "@/app/lib/multiply-system/contracts"
import { RAY, TOKEN_SCALE } from "@/app/lib/credit-engine/units"
import { getSwapAsset } from "@/app/lib/swap-system/catalog"
import type { SwapTransactionRecord } from "@/app/lib/swap-system/transaction-adapter"

type RecordTransactionArgs = {
  wallet: string
  intentId: string
  product: "borrow" | "lend" | "multiply"
  kind: string
  marketSlug?: string
  assetId?: string
  requestedAmountUsd6: string
  executedAmountUsd6: string
  amountUsd: number
  tokenAmount?: number
  simulated: boolean
  /** Optimistic-concurrency token: the position revision this write was computed from.
   *  The server rejects the write (STALE_WRITE) if the stored position has advanced past it. */
  expectedRevision?: number
  /** Per-transaction multiply leverage, persisted so hydrated history renders the real
   *  before→after (e.g. "3.00x → 2.00x") instead of a constant 1 × current multiplier. */
  multiplierBefore?: number
  multiplierAfter?: number
  /** Remaining claimable per borrow LP-fee reward position after a claim (usd6 strings),
   *  so claimable survives reload instead of resetting to the seeded full amount. */
  rewardClaims?: Array<{ rewardPositionId: string; remainingUsd6: string }>
  position?: {
    status: "open" | "closed"
    marketSlug?: string
    assetId?: string
    collateralValueUsd6?: string
    debtValueUsd6?: string
    suppliedUsd6?: string
    earnedUsd6?: string
    supplyApyPct?: number
    collateralAmount?: number
    collateralValueUsd?: number
    debtValueUsd?: number
    multiplier?: number
    ltv?: number
    healthFactor?: number | "infinity"
    liquidationPrice?: number | null
    netApyPct?: number
    collateral?: Array<{
      marketSlug: string
      collateralShares: string
      principalTokenAmount: string
      collateralEnabled: boolean
      collateralValueUsd6?: string
    }>
    debt?: Array<{
      assetId: string
      baseAssetId: string
      spokeId?: string
      marketSlug?: string
      debtSharesUsd6: string
      debtIndexRay: string
      borrowRateWad: string
      principalBorrowedUsd6: string
    }>
  }
}

export function lendResultToRecordArgs(result: LendSandboxActionResult, wallet: string): RecordTransactionArgs {
  const item = result.historyItem
  const position = item.positionId ? result.state.positions[item.positionId] : undefined
  // `item.amount` is TOKEN-denominated (e.g. 1 ETH). The server reconciles the supplied
  // balance in USD (position.suppliedValueUsd), so the transaction amount and the liquidity
  // delta must be USD too — otherwise every non-$1 asset (ETH, BTC, …) trips
  // INVALID_TRANSITION on execute and lend is silently restricted to $1 stablecoins.
  const assetPriceUsd = result.state.markets[item.marketId]?.assetPriceUsd ?? 1
  const amountUsd = item.amount * assetPriceUsd
  return {
    wallet,
    intentId: item.intentId,
    product: "lend",
    kind: item.kind,
    marketSlug: item.marketId,
    requestedAmountUsd6: Math.round(amountUsd * 1_000_000).toString(),
    executedAmountUsd6: Math.round(amountUsd * 1_000_000).toString(),
    amountUsd,
    // The typed token quantity; the server books it when its price agrees with the oracle.
    tokenAmount: item.kind === "claim" ? undefined : item.amount,
    simulated: item.simulated,
    position: position
      ? {
          status: position.status === "active" ? "open" : "closed",
          marketSlug: position.marketId,
          suppliedUsd6: Math.round(position.suppliedValueUsd * 1_000_000).toString(),
          earnedUsd6: Math.round(position.interestEarned * assetPriceUsd * 1_000_000).toString(),
          supplyApyPct: (result.state.markets[item.marketId]?.totalApy ?? 0) * 100,
        }
      : undefined,
  }
}

export function multiplyResultToRecordArgs(result: MultiplySandboxActionResult, wallet: string): RecordTransactionArgs {
  const item = result.historyItem
  const position = Object.values(result.state.positions)
    .filter((entry) => entry.marketId === item.marketId)
    .sort((a, b) => b.lastUpdatedAt - a.lastUpdatedAt)[0]
  const marketSlug = position?.marketId ?? item.marketId
  const collateralAssetId = marketSlug
    ? result.state.markets?.[marketSlug]?.collateralAsset.symbol.toLowerCase()
    : undefined

  // A successful close DELETES the position from engine state, so it can't be read back here.
  // Without an explicit closed payload recordTransaction skips its close branch and the server
  // row stays status:"open" forever — the position resurrects on reload with stale debt.
  const closedByDelete = !position && item.status === "success" && item.kind === "close" && Boolean(marketSlug)
  const amountUsd =
    item.kind === "deleverage" && result.preview
      ? Math.max(0, result.preview.before.debtValueUsd - result.preview.after.debtValueUsd)
      : item.amountUsd

  return {
    wallet,
    intentId: item.intentId,
    product: "multiply",
    kind: item.kind,
    marketSlug,
    requestedAmountUsd6: Math.round(amountUsd * 1_000_000).toString(),
    executedAmountUsd6: Math.round(amountUsd * 1_000_000).toString(),
    amountUsd,
    simulated: item.simulated,
    // Persist the leverage at THIS transaction so hydrated history shows the real before→after.
    multiplierBefore: item.multiplierBefore,
    multiplierAfter: item.multiplierAfter,
    position: position
      ? {
          // A position still present in engine state is OPEN, including a fully deleveraged
          // 1x/$0 one the engine deliberately keeps. "Closed" is signalled ONLY by deletion
          // (closedByDelete above); inferring it from multiplier <= 1 diverges from local state.
          status: "open",
          marketSlug: position.marketId,
          assetId: collateralAssetId,
          collateralAmount: position.collateralAmount,
          collateralValueUsd: position.collateralValueUsd,
          debtValueUsd: position.debtValueUsd,
          multiplier: position.multiplier,
          ltv: position.ltv,
          healthFactor: position.healthFactor,
          liquidationPrice: position.liquidationPrice,
          netApyPct: position.netApy,
        }
      : closedByDelete
        ? {
            status: "closed",
            marketSlug,
            assetId: collateralAssetId,
            collateralAmount: 0,
            collateralValueUsd: 0,
            debtValueUsd: 0,
            multiplier: 1,
            ltv: 0,
            healthFactor: "infinity",
            liquidationPrice: null,
            netApyPct: 0,
          }
        : undefined,
  }
}

/** usd6 bigint → human USD number (UI-edge conversion). */
function usd6ToNumber(value: bigint): number {
  return Number(value) / 1_000_000
}

/**
 * Convert a successful borrow-system history item into recordTransaction args. The
 * idempotency key is the item's intentId, so replays (reloads, double sends) collapse
 * onto one row server-side.
 */
function borrowHistoryItemToRecordArgs(item: TransactionHistoryItem, wallet: string): RecordTransactionArgs {
  return {
    wallet,
    intentId: item.intentId,
    product: "borrow",
    kind: item.kind,
    marketSlug: item.marketId,
    assetId: item.assetId,
    requestedAmountUsd6: item.requestedAmountUsd6.toString(),
    executedAmountUsd6: item.executedAmountUsd6.toString(),
    amountUsd: usd6ToNumber(item.executedAmountUsd6),
    simulated: item.simulated,
  }
}

export function borrowResultToRecordArgs(result: SandboxActionResult, wallet: string): RecordTransactionArgs {
  const base = borrowHistoryItemToRecordArgs(result.historyItem, wallet)
  const account = result.state.accounts[wallet]

  // Claim carries no market position — persist the post-claim remaining claimable per
  // reward position instead, so claimable survives reload (hydration reduces the seeded
  // claimable to this). Sent as absolute usd6 remaining, not a delta.
  if (result.historyItem.kind === "claim") {
    const rewardClaims = (account?.rewardPositions ?? []).map((position) => ({
      rewardPositionId: position.id,
      remainingUsd6: position.claimableUsd6.toString(),
    }))
    return rewardClaims.length > 0 ? { ...base, rewardClaims } : base
  }

  const marketSlug =
    result.historyItem.marketId ??
    [...result.state.transactions]
      .reverse()
      .find(
        (transaction) =>
          transaction.walletId === wallet &&
          transaction.at === result.historyItem.timestamp &&
          transaction.kind === result.historyItem.kind,
      )?.marketId
  if (!account || !marketSlug) return base

  const collateral = account.collateralPositions
    .filter((position) => position.marketId === marketSlug)
    .map((position) => {
      const market = result.state.markets[position.marketId]
      const tokenAmount = market ? (position.collateralShares * market.snapshot.supplyIndexRay) / RAY : 0n
      return {
        marketSlug: position.marketId,
        collateralShares: position.collateralShares.toString(),
        principalTokenAmount: position.principalTokenAmount.toString(),
        collateralEnabled: position.collateralEnabled,
        collateralValueUsd6: market
          ? ((tokenAmount * market.snapshot.lpTokenPriceUsd6) / TOKEN_SCALE).toString()
          : undefined,
      }
    })
  const debt = account.debtPositions
    .filter((position) => position.marketId === marketSlug)
    .map((position) => ({
      assetId: position.assetId,
      baseAssetId: position.baseAssetId,
      spokeId: position.spokeId,
      marketSlug: position.marketId,
      debtSharesUsd6: position.debtSharesUsd6.toString(),
      debtIndexRay: position.debtIndexRay.toString(),
      borrowRateWad: position.borrowRateWad.toString(),
      principalBorrowedUsd6: position.principalBorrowedUsd6.toString(),
    }))

  return {
    ...base,
    marketSlug,
    position: {
      status: collateral.length === 0 && debt.length === 0 ? "closed" : "open",
      marketSlug,
      collateralValueUsd6: result.preview.after.collateralValueUsd6.toString(),
      debtValueUsd6: result.preview.after.totalBorrowedUsd6.toString(),
      collateral,
      debt,
    },
  }
}

type RecordSwapArgs = {
  wallet: string
  intentId: string
  status: "success" | "failed" | "pending"
  inputAssetId: string
  outputAssetId: string
  inputSymbol: string
  outputSymbol: string
  inputAmount: number
  outputAmount: number
  amountUsd: number
  provider?: string
  quoteId?: string
  networkFeeUsd?: number
  minOutputAmount?: number
  priceImpactPct?: number
  slippageBps?: number
  simulated: boolean
  syntheticTxHash?: string
}

/**
 * Map an executed swap onto the Convex `recordSwap` args, or `null` for a non-terminal
 * record (approval gate / in-flight) that isn't a persistable outcome. The idempotency key
 * is the client swap id, so a replay returns the existing row. amountUsd is the input leg's
 * USD value (the server zeroes it for a non-success status).
 */
export function swapRecordToRecordSwapArgs(record: SwapTransactionRecord, wallet: string): RecordSwapArgs | null {
  const status: RecordSwapArgs["status"] | null =
    record.status === "confirmed"
      ? "success"
      : record.status === "failed" || record.status === "expired" || record.status === "rejected"
        ? "failed"
        : null
  if (status === null) return null

  const input = getSwapAsset(record.inputAssetId)
  const output = getSwapAsset(record.outputAssetId)
  return {
    wallet,
    intentId: record.id,
    status,
    inputAssetId: record.inputAssetId,
    outputAssetId: record.outputAssetId,
    inputSymbol: input?.symbol ?? record.inputAssetId.toUpperCase(),
    outputSymbol: output?.symbol ?? record.outputAssetId.toUpperCase(),
    inputAmount: record.inputAmount,
    outputAmount: record.outputAmount,
    amountUsd: record.inputAmount * (input?.priceUsd ?? 0),
    provider: record.provider,
    quoteId: record.quoteId,
    networkFeeUsd: record.networkFeeUsd,
    minOutputAmount: record.minimumOutputAmount,
    priceImpactPct: record.priceImpactPct,
    slippageBps: record.slippageBps,
    simulated: true,
    syntheticTxHash: record.swapTransactionHash ?? undefined,
  }
}
