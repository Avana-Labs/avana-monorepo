import type { PositionConstituent, PositionSnapshotInput } from "./position-context"

/**
 * Bridge from Convex row shapes to the engine's {@link PositionSnapshotInput}. Takes plain row
 * objects rather than a `ctx` so the field mapping — the part most likely to drift from the
 * schema — stays unit-testable without Convex.
 */

const USD6 = 1_000_000

/** The subset of a `positions` row the engine needs. Mirrors convex/schema.ts. */
export type PositionRow = {
  _id: string
  product: "borrow" | "multiply" | "lend" | "umbrella"
  marketSlug: string
  assetId?: string
  status: "open" | "closed"
  // borrow/lend carry usd6 decimal strings; multiply carries number-native fields.
  collateralValueUsd6?: string
  debtValueUsd6?: string
  collateralValueUsd?: number
  debtValueUsd?: number
  lastUpdatedAt?: number
}

/** The subset of a `markets` row the engine needs. */
export type MarketRow = {
  maxLtvPct?: number
  priceUsd?: number
  constituents?: Array<{ symbol: string; weight: number }>
}

/** The subset of a `multiplyTokenParameters` row the engine needs. */
type TokenParameterRow = {
  borrowAprPct?: number
  collateralFactorPct?: number
  liquidationThresholdPct?: number
}

const usd6ToNumber = (value: string | undefined): number => (value ? Number(value) / USD6 : 0)

/**
 * Map joined Convex rows to a snapshot input. Missing fields stay `undefined` so the
 * engine's null-honest behaviour holds — e.g. no LP fee-APR column exists today, so
 * `lpFeeApr7dPct` is always omitted and fee/carry numbers come back null rather than 0.
 */
export function positionInputFromRows(args: {
  position: PositionRow
  market?: MarketRow | null
  parameter?: TokenParameterRow | null
  asOf: number
}): PositionSnapshotInput {
  const { position, market, parameter, asOf } = args
  const collateralValueUsd = position.collateralValueUsd ?? usd6ToNumber(position.collateralValueUsd6)
  const debtValueUsd = position.debtValueUsd ?? usd6ToNumber(position.debtValueUsd6)
  const constituents: PositionConstituent[] =
    market?.constituents?.map((c) => ({ symbol: c.symbol, weight: c.weight })) ??
    (position.assetId ? [{ symbol: position.assetId, weight: 1 }] : [])

  return {
    positionId: position._id,
    product: position.product,
    collateralValueUsd,
    debtValueUsd,
    maxLtvPct: market?.maxLtvPct ?? parameter?.collateralFactorPct ?? 0,
    liquidationThresholdPct: parameter?.liquidationThresholdPct,
    borrowApyPct: parameter?.borrowAprPct,
    lpFeeApr7dPct: undefined,
    constituents,
    lastUpdatedAt: position.lastUpdatedAt ?? asOf,
  }
}
