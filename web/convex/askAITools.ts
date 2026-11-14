import { v } from "convex/values"
import { ASK_AI_CONFIG, ASK_AI_WALLET_REQUIRED } from "../app/lib/ask-ai/config"
import type { AskAIMarketSource } from "../app/lib/ask-ai/providers/contracts"
import {
  calculateLendProjection,
  calculateAskAIBorrowSimulation,
  calculateAskAICollateralStress,
  calculateMultiplyStress,
  decodeBorrowRiskSnapshot,
  deriveAskAIUmbrellaStatus,
  askAIHealthFactorValue,
  askAIRiskLevel,
  calculateBorrowProjection,
} from "../app/lib/ask-ai/engine-calculations"
import { internalQuery, query, type MutationCtx, type QueryCtx } from "./_generated/server"
import { calculatePriceDropToLiquidationPct } from "../app/lib/multiply-engine/formulas"
import { catalogMultiplyNetApyPct } from "../app/lib/multiply-system/catalog"
import { getAuthedWallet } from "./sandbox/auth"
import { computePortfolioNetApyPct } from "./sandbox/transactions"
import type { Id } from "./_generated/dataModel"

/** Money is shown to the cent, so the model is handed cents (not 962728.1321171904). */
const toCents = (usd: number) => Math.round(usd * 100) / 100

/**
 * Rounds every `*Usd` total to the cent, then rebuilds Net Value from the ROUNDED components so
 * "Lend + Borrow + Liquid + Multiply = Net value" still adds up exactly in what the user reads.
 */
export function toCentsTotals<T extends Record<string, unknown>>(totals: T): T {
  const rounded: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(totals)) {
    rounded[key] = key.endsWith("Usd") && typeof value === "number" && Number.isFinite(value) ? toCents(value) : value
  }
  const parts = ["lendNetValueUsd", "borrowNetValueUsd", "multiplyNetValueUsd", "liquidNetValueUsd"] as const
  if (parts.every((key) => typeof rounded[key] === "number")) {
    rounded.netValueUsd = toCents(parts.reduce((sum, key) => sum + (rounded[key] as number), 0))
  }
  return rounded as T
}

type PortfolioReadCtx = Pick<QueryCtx | MutationCtx, "auth" | "db">

function withTurnWallet(ctx: Pick<QueryCtx, "db">, wallet?: string): PortfolioReadCtx {
  return {
    db: ctx.db,
    auth: {
      getUserIdentity: async () =>
        ({
          subject: wallet ?? "ask-guest:scheduled",
          ...(wallet ? { wallet } : {}),
        }) as Awaited<ReturnType<QueryCtx["auth"]["getUserIdentity"]>>,
    },
  }
}

async function readRunningTurnWallet(ctx: Pick<QueryCtx, "db">, turnId: Id<"askAITurns">) {
  const turn = await ctx.db.get(turnId)
  if (!turn || turn.status !== "running") throw new Error("Ask AI turn is not running")
  return turn.wallet
}

// Scheduled actions have no client auth: the queue stamped this wallet from the authenticated
// identity, and a model can only supply the running turn ID internally.
export const aaveWalletForTurn = internalQuery({
  args: { turnId: v.id("askAITurns") },
  handler: async (ctx, { turnId }) => (await readRunningTurnWallet(ctx, turnId)) ?? null,
})

/**
 * Provenance of the financial figures every Ask AI portfolio/risk tool returns, passed
 * through into `richParts.financialResults[].dataProvenance`.
 *
 * Every figure these tools read is written by the synthetic sandbox flow, and no table
 * carries a per-record origin signal, so "sandbox" is the only honest value. The authed
 * wallet scopes access; it does not imply the data is real holdings.
 *
 * TODO: when a real connected-wallet or on-chain path lands, stamp a per-record origin at
 * write time and return "connected_wallet" / "onchain" per record instead of this constant.
 */
const ASK_AI_DATA_PROVENANCE: "sandbox" | "connected_wallet" | "onchain" = "sandbox"

export async function readAskAIPortfolio(ctx: PortfolioReadCtx) {
  const wallet = await getAuthedWallet(ctx)
  if (!wallet) return { walletRequired: true as const, message: ASK_AI_WALLET_REQUIRED }

  const [lend, borrow, multiply, liquid, allPositions, umbrellaTranches, current, walletCollateral] = await Promise.all(
    [
      ctx.db
        .query("walletLendBalances")
        .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
        .collect(),
      ctx.db
        .query("walletBorrowBalances")
        .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
        .collect(),
      ctx.db
        .query("walletMultiplyBalances")
        .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
        .collect(),
      ctx.db
        .query("walletLiquidBalances")
        .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
        .collect(),
      ctx.db
        .query("positions")
        .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
        .collect(),
      ctx.db
        .query("umbrellaCooldownTranches")
        .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
        .collect(),
      // Carries the wallet's cumulative earnings, which no per-row balance does.
      ctx.db
        .query("portfolioCurrent")
        .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
        .unique(),
      // Needed by the shared Net APY calculation.
      ctx.db
        .query("walletCollateralPositions")
        .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
        .collect(),
    ],
  )
  const umbrella = allPositions.filter((position) => position.product === "umbrella")

  const sumUsd = (rows: readonly { valueUsd: number }[]) => rows.reduce((sum, row) => sum + row.valueUsd, 0)
  // Debt is stored with a POSITIVE valueUsd and marked only by `state: "debt"`, so a plain
  // sum counts borrowed value as an asset. Any net figure MUST subtract these rows.
  const netUsd = (rows: readonly { valueUsd: number; state?: string }[]) =>
    rows.reduce((sum, row) => sum + (row.state === "debt" ? -row.valueUsd : row.valueUsd), 0)
  // walletMultiplyBalances records the SAME collateral twice, as `state:"position"` and
  // `state:"collateral"`, so a raw sum double-counts it. Drop the "collateral" row, exactly as
  // the dashboard does in app/lib/swap-system/use-convex-wallet-balances.ts.
  const multiplyRows = multiply.filter((row) => row.state !== "collateral")
  // A lend withdrawal credits BOTH the liquid row and the lend `available` bucket, and unpledged
  // LP sits in both the liquid row and borrow `poolAvailable`: the same tokens twice. The dashboard
  // (aggregateNetValueUsd) skips those mirrors when a liquid row holds the asset; so does Net Value.
  const liquidAssetIds = new Set(liquid.map((row) => row.assetId))
  const lendForNetValue = lend.filter((row) => !(row.state === "available" && liquidAssetIds.has(row.assetId)))
  const borrowForNetValue = borrow.filter(
    (row) => !(row.state === "poolAvailable" && liquidAssetIds.has(row.poolId ?? row.assetId ?? row.marketId ?? "")),
  )
  const sumState = (rows: readonly { valueUsd: number; state: string }[], ...states: string[]) =>
    sumUsd(rows.filter((row) => states.includes(row.state)))
  // "What is my biggest position?" — debt rows are obligations, not holdings.
  const largest = [
    ...lend.map((row) => ({ label: `Lend ${row.symbol}`, valueUsd: row.valueUsd, state: row.state as string })),
    ...borrow.map((row) => ({ label: `Borrow ${row.symbol}`, valueUsd: row.valueUsd, state: row.state as string })),
    ...multiplyRows.map((row) => ({
      label: `Multiply ${row.symbol}`,
      valueUsd: row.valueUsd,
      state: row.state as string,
    })),
    ...liquid.map((row) => ({ label: `Liquid ${row.symbol}`, valueUsd: row.valueUsd, state: row.state as string })),
  ]
    .filter((row) => row.state !== "debt")
    .sort((a, b) => b.valueUsd - a.valueUsd)[0]
  const now = Date.now()
  const umbrellaPositions = umbrella.map((position) => ({
    ...position,
    suppliedUsd: Number(position.suppliedUsd6 ?? "0") / 1_000_000,
    cooldownUsd: Number(position.cooldownAmountUsd6 ?? "0") / 1_000_000,
    // Decoded here; the raw doc carries these only as usd6 strings.
    earnedUsd: Number(position.earnedUsd6 ?? "0") / 1_000_000,
    slashedUsd: Number(position.slashedAmountUsd6 ?? "0") / 1_000_000,
    lifecycleStatus: deriveAskAIUmbrellaStatus({ ...position, now }),
    remainingCooldownMs: Math.max(0, (position.cooldownEndsAt ?? 0) - now),
    remainingWithdrawalWindowMs: Math.max(0, (position.withdrawalWindowEndsAt ?? 0) - now),
  }))
  const umbrellaCooldowns = umbrellaTranches.flatMap((tranche) => {
    const amountUsd = Number(tranche.amountUsd6) / 1_000_000
    if (tranche.status === "consumed" || amountUsd <= 0) return []
    const status = now < tranche.endsAt ? "cooling" : now <= tranche.windowEndsAt ? "ready" : "expired"
    return [
      {
        positionId: tranche.positionId,
        marketId: tranche.marketId,
        amountUsd,
        status,
        startedAt: tranche.startedAt,
        endsAt: tranche.endsAt,
        windowEndsAt: tranche.windowEndsAt,
        remainingCooldownMs: status === "cooling" ? tranche.endsAt - now : 0,
        remainingWithdrawalWindowMs: status === "ready" ? tranche.windowEndsAt - now : 0,
        canWithdraw: status === "ready",
      },
    ]
  })
  const cooling = umbrellaCooldowns.filter((tranche) => tranche.status === "cooling")
  const ready = umbrellaCooldowns.filter((tranche) => tranche.status === "ready")
  const expired = umbrellaCooldowns.filter((tranche) => tranche.status === "expired")
  const umbrellaSuppliedUsd = umbrella.reduce(
    (sum, position) => sum + Number(position.suppliedUsd6 ?? "0") / 1_000_000,
    0,
  )

  return {
    walletRequired: false as const,
    dataProvenance: ASK_AI_DATA_PROVENANCE,
    wallet,
    totals: toCentsTotals({
      // Gross exposure per product (collateral + debt), for callers wanting position size.
      lendUsd: sumUsd(lend),
      borrowUsd: sumUsd(borrow),
      multiplyUsd: sumUsd(multiplyRows),
      liquidUsd: sumUsd(liquid),
      umbrellaUsd: umbrellaSuppliedUsd,
      // Equity per product: the same rows with debt subtracted.
      lendNetUsd: netUsd(lend),
      borrowNetUsd: netUsd(borrow),
      multiplyNetUsd: netUsd(multiplyRows),
      liquidNetUsd: netUsd(liquid),
      // These are the exact component values used by the canonical Net Value
      // calculation below. The older *NetUsd fields intentionally remain as
      // raw product totals for callers that need gross product accounting.
      lendNetValueUsd: netUsd(lendForNetValue),
      borrowNetValueUsd: netUsd(borrowForNetValue),
      multiplyNetValueUsd: netUsd(multiplyRows),
      liquidNetValueUsd: netUsd(liquid),
      // Canonical Net Value, matching the dashboard hero (aggregateNetValueUsd): signed sum of
      // liquid + lend + borrow + multiply with debt negative. Umbrella is EXCLUDED there, so it
      // is excluded here too and reported separately as umbrellaUsd.
      netValueUsd: netUsd(liquid) + netUsd(lendForNetValue) + netUsd(borrowForNetValue) + netUsd(multiplyRows),
      // Cumulative; not derivable from the balances above.
      totalEarnedUsd: current?.totalEarnedUsd ?? 0,
      // The gross totals above deliberately mix states (lend "available" beside "deposited";
      // borrow collateral beside debt and claimable fees), so each state gets its own figure
      // rather than leaving the model to filter rows and add money itself.
      suppliedUsd: sumState(lend, "deposited"),
      idleLendUsd: sumState(lend, "available"),
      debtUsd: sumState(borrow, "debt") + sumState(multiplyRows, "debt"),
      collateralUsd: sumState(borrow, "collateral") + sumState(multiplyRows, "position"),
      unpledgedCollateralUsd: sumState(borrow, "poolAvailable"),
      claimableUsd: sumState(borrow, "claimableFees"),
      // Same helper the dashboard uses, so the two surfaces cannot drift.
      netApyPct: await computePortfolioNetApyPct(ctx, allPositions, walletCollateral),
      openPositionCount: allPositions.filter((position) => position.status === "open").length,
      umbrellaEarnedUsd: umbrellaPositions.reduce((sum, position) => sum + position.earnedUsd, 0),
      umbrellaSlashedUsd: umbrellaPositions.reduce((sum, position) => sum + position.slashedUsd, 0),
      largestPositionUsd: largest?.valueUsd ?? 0,
      largestPositionLabel: largest?.label ?? null,
    }),
    lend,
    borrow,
    multiply,
    liquid,
    umbrella: umbrellaPositions,
    umbrellaCooldowns,
    umbrellaCooldownSummary: {
      coolingCount: cooling.length,
      coolingUsd: toCents(cooling.reduce((sum, tranche) => sum + tranche.amountUsd, 0)),
      readyCount: ready.length,
      readyUsd: toCents(ready.reduce((sum, tranche) => sum + tranche.amountUsd, 0)),
      expiredCount: expired.length,
      expiredUsd: toCents(expired.reduce((sum, tranche) => sum + tranche.amountUsd, 0)),
      nextCooldownEndsAt: cooling.length > 0 ? Math.min(...cooling.map((tranche) => tranche.endsAt)) : null,
      nextWithdrawalWindowEndsAt: ready.length > 0 ? Math.min(...ready.map((tranche) => tranche.windowEndsAt)) : null,
    },
    asOf: Math.max(
      0,
      ...lend.map((row) => row.updatedAt),
      ...borrow.map((row) => row.updatedAt),
      ...multiply.map((row) => row.updatedAt),
      ...liquid.map((row) => row.updatedAt),
      ...umbrella.map((row) => row.lastUpdatedAt),
      ...umbrellaTranches.map((row) => row.updatedAt),
    ),
  }
}

export const portfolio = query({
  args: {},
  handler: readAskAIPortfolio,
})

export const portfolioForTurn = internalQuery({
  args: { turnId: v.id("askAITurns") },
  handler: async (ctx, { turnId }) => readAskAIPortfolio(withTurnWallet(ctx, await readRunningTurnWallet(ctx, turnId))),
})

export async function readAskAIEngineSnapshot(
  ctx: PortfolioReadCtx,
  { multiplyShockPct, lendProjectionDays }: { multiplyShockPct?: number; lendProjectionDays?: number },
) {
  const wallet = await getAuthedWallet(ctx)
  if (!wallet) return { walletRequired: true as const, message: ASK_AI_WALLET_REQUIRED }

  const [positions, borrowRisk, multiplyParameters] = await Promise.all([
    ctx.db
      .query("positions")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .collect(),
    ctx.db
      .query("riskSnapshots")
      .withIndex("by_wallet_at", (q) => q.eq("wallet", wallet))
      .order("desc")
      .first(),
    ctx.db.query("multiplyTokenParameters").collect(),
  ])

  const parameterBySymbol = new Map(multiplyParameters.map((row) => [row.symbol.toLowerCase(), row]))
  const now = Date.now()
  const lendDays = Math.min(Math.max(lendProjectionDays ?? 30, 1), 365)
  const shockPct = Math.min(Math.max(multiplyShockPct ?? -20, -95), 100)

  const lendPositions = positions
    .filter((position) => position.product === "lend" && position.status === "open")
    .map((position) => {
      const principalUsd = Number(position.suppliedUsd6 ?? "0") / 1_000_000
      return {
        engine: "lend-engine" as const,
        marketSlug: position.marketSlug,
        principalUsd,
        earnedUsd: Number(position.earnedUsd6 ?? "0") / 1_000_000,
        projection: calculateLendProjection({
          principalUsd,
          supplyApyPct: position.supplyApyPct ?? 0,
          days: lendDays,
        }),
      }
    })
  const multiplyPositions = positions
    .filter((position) => position.product === "multiply" && position.status === "open")
    .map((position) => {
      const parameters = parameterBySymbol.get((position.assetId ?? "").toLowerCase())
      const collateralValueUsd = position.collateralValueUsd ?? 0
      const collateralAmount = position.collateralAmount ?? 0
      return {
        engine: "multiply-engine" as const,
        marketSlug: position.marketSlug,
        collateralValueUsd,
        debtValueUsd: position.debtValueUsd ?? 0,
        equityUsd: collateralValueUsd - (position.debtValueUsd ?? 0),
        // Leverage / net APY / liquidation price were on the doc but never reached the model.
        multiplier: position.multiplier ?? null,
        netApyPct: catalogMultiplyNetApyPct(position.marketSlug, collateralValueUsd, position.debtValueUsd ?? 0),
        liquidationPrice: position.liquidationPrice ?? null,
        priceDropToLiquidationPct: calculatePriceDropToLiquidationPct(
          position.liquidationPrice ?? null,
          collateralAmount > 0 ? collateralValueUsd / collateralAmount : 0,
        ),
        ...askAIHealthFactorValue(position.healthFactor),
        persistedHealthFactor: position.healthFactor ?? null,
        stress: parameters
          ? calculateMultiplyStress({
              collateralValueUsd: position.collateralValueUsd ?? 0,
              debtValueUsd: position.debtValueUsd ?? 0,
              liquidationThresholdPct: parameters.liquidationThresholdPct,
              collateralPriceShockPct: shockPct,
            })
          : null,
        stressUnavailableReason: parameters ? null : "Missing multiply token risk parameters",
      }
    })
  const umbrellaEnginePositions = positions
    .filter((position) => position.product === "umbrella")
    .map((position) => ({
      engine: "umbrella-system" as const,
      marketSlug: position.marketSlug,
      suppliedUsd: Number(position.suppliedUsd6 ?? "0") / 1_000_000,
      earnedUsd: Number(position.earnedUsd6 ?? "0") / 1_000_000,
      cooldownUsd: Number(position.cooldownAmountUsd6 ?? "0") / 1_000_000,
      slashedUsd: Number(position.slashedAmountUsd6 ?? "0") / 1_000_000,
      status: deriveAskAIUmbrellaStatus({ ...position, now }),
    }))
  const total = (values: readonly number[]) => values.reduce((sum, value) => sum + value, 0)
  // Health factors have no meaningful average across positions; report the WEAKEST one.
  const multiplyHealthFactors = multiplyPositions
    .map((position) => position.persistedHealthFactor)
    .filter((value): value is number => typeof value === "number" && Number.isFinite(value))
  const stressedHealthFactors = multiplyPositions
    .map((position) => position.stress?.healthFactor)
    .filter((value): value is number => typeof value === "number" && Number.isFinite(value))

  return {
    walletRequired: false as const,
    dataProvenance: ASK_AI_DATA_PROVENANCE,
    wallet,
    // One scalar per question, computed here so the model never does money arithmetic.
    // Health factor is the weakest position, not a mean.
    summary: {
      lendPositionCount: lendPositions.length,
      lendPrincipalUsd: total(lendPositions.map((position) => position.principalUsd)),
      lendEarnedUsd: total(lendPositions.map((position) => position.earnedUsd)),
      lendProjectedYieldUsd: total(lendPositions.map((position) => position.projection.projectedYieldUsd)),
      lendProjectionDays: lendDays,
      multiplyPositionCount: multiplyPositions.length,
      multiplyCollateralUsd: total(multiplyPositions.map((position) => position.collateralValueUsd)),
      multiplyDebtUsd: total(multiplyPositions.map((position) => position.debtValueUsd)),
      multiplyEquityUsd: total(
        multiplyPositions.map((position) => position.collateralValueUsd - position.debtValueUsd),
      ),
      multiplyWeakestHealthFactor: multiplyHealthFactors.length ? Math.min(...multiplyHealthFactors) : null,
      multiplyShockPct: shockPct,
      multiplyWeakestHealthFactorAfterShock: stressedHealthFactors.length ? Math.min(...stressedHealthFactors) : null,
      multiplyLiquidatableAfterShock: stressedHealthFactors.some((value) => value <= 1),
      umbrellaPositionCount: umbrellaEnginePositions.length,
      umbrellaSuppliedUsd: total(umbrellaEnginePositions.map((position) => position.suppliedUsd)),
      umbrellaEarnedUsd: total(umbrellaEnginePositions.map((position) => position.earnedUsd)),
      umbrellaSlashedUsd: total(umbrellaEnginePositions.map((position) => position.slashedUsd)),
    },
    borrow: borrowRisk
      ? {
          engine: "credit-engine" as const,
          at: borrowRisk.at,
          ...decodeBorrowRiskSnapshot(borrowRisk),
          spokes: borrowRisk.spokes.map((spoke) => ({
            spokeId: spoke.spokeId,
            availableCreditUsd: Number(spoke.availableCreditUsd6) / 1_000_000,
            totalBorrowedUsd: Number(spoke.totalBorrowedUsd6) / 1_000_000,
            liquidationBufferUsd: Number(spoke.liquidationBufferUsd6) / 1_000_000,
            healthFactor:
              spoke.healthFactorWad === null ? null : Number(spoke.healthFactorWad) / 1_000_000_000_000_000_000,
          })),
        }
      : null,
    lend: lendPositions,
    multiply: multiplyPositions,
    umbrella: umbrellaEnginePositions,
    asOf: Math.max(0, borrowRisk?.at ?? 0, ...positions.map((position) => position.lastUpdatedAt)),
  }
}

export const engineSnapshot = query({
  args: { multiplyShockPct: v.optional(v.number()), lendProjectionDays: v.optional(v.number()) },
  handler: readAskAIEngineSnapshot,
})

export async function readAskAIBorrowCapacity(ctx: PortfolioReadCtx) {
  const wallet = await getAuthedWallet(ctx)
  if (!wallet) return { walletRequired: true as const, message: ASK_AI_WALLET_REQUIRED }
  const [snapshot, portfolio, borrowBalances] = await Promise.all([
    ctx.db
      .query("riskSnapshots")
      .withIndex("by_wallet_at", (q) => q.eq("wallet", wallet))
      .order("desc")
      .first(),
    ctx.db
      .query("portfolioCurrent")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .unique(),
    ctx.db
      .query("walletBorrowBalances")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .collect(),
  ])
  // portfolioCurrent.totalBorrowedUsd is portfolio-wide and includes Multiply debt. Borrow
  // capacity must only use debt from the Borrow product, otherwise a newly onboarded wallet
  // with the starter Multiply allocation appears to have already borrowed against LP collateral.
  const borrowDebtUsd = borrowBalances
    .filter((row) => row.state === "debt")
    .reduce((sum, row) => sum + Math.max(0, row.valueUsd), 0)
  const capacity = snapshot
    ? { ...decodeBorrowRiskSnapshot(snapshot), source: "credit_engine_snapshot" as const }
    : portfolio
      ? {
          borrowCapacityUsd: portfolio.availableToBorrowUsd + borrowDebtUsd,
          availableBorrowCapacityUsd: portfolio.availableToBorrowUsd,
          totalBorrowedUsd: borrowDebtUsd,
          source: "portfolio_current" as const,
        }
      : null
  // Decode the usd6 strings and wad health factor before they reach the model. Every money
  // value in this result is already denominated in USD, so the model never does unit conversion.
  const spokes = (snapshot?.spokes ?? []).map((spoke) => ({
    spokeId: spoke.spokeId,
    availableCreditUsd: Number(spoke.availableCreditUsd6) / 1_000_000,
    totalBorrowedUsd: Number(spoke.totalBorrowedUsd6) / 1_000_000,
    liquidationBufferUsd: Number(spoke.liquidationBufferUsd6) / 1_000_000,
    ...askAIHealthFactorValue(
      spoke.healthFactorWad === null ? "infinity" : Number(spoke.healthFactorWad) / 1_000_000_000_000_000_000,
    ),
  }))
  const capacityHealthFactor = capacity && "healthFactor" in capacity ? capacity.healthFactor : undefined
  const healthFactorValue =
    capacity && capacity.totalBorrowedUsd === 0
      ? askAIHealthFactorValue("infinity")
      : askAIHealthFactorValue(capacityHealthFactor)
  return {
    walletRequired: false as const,
    dataProvenance: ASK_AI_DATA_PROVENANCE,
    wallet,
    capacity: capacity
      ? {
          ...capacity,
          // The tool description promises a liquidation buffer, but only the raw spokes had it.
          liquidationBufferUsd: spokes.reduce((sum, spoke) => sum + spoke.liquidationBufferUsd, 0),
          ...healthFactorValue,
        }
      : null,
    spokes,
    asOf: snapshot?.at ?? portfolio?.at ?? 0,
  }
}

export const borrowCapacity = query({ args: {}, handler: readAskAIBorrowCapacity })

export const engineSnapshotForTurn = internalQuery({
  args: {
    turnId: v.id("askAITurns"),
    multiplyShockPct: v.optional(v.number()),
    lendProjectionDays: v.optional(v.number()),
  },
  handler: async (ctx, { turnId, ...args }) =>
    readAskAIEngineSnapshot(withTurnWallet(ctx, await readRunningTurnWallet(ctx, turnId)), args),
})

export const borrowCapacityForTurn = internalQuery({
  args: { turnId: v.id("askAITurns") },
  handler: async (ctx, { turnId }) =>
    readAskAIBorrowCapacity(withTurnWallet(ctx, await readRunningTurnWallet(ctx, turnId))),
})

export async function readAskAIPositionRisk(ctx: PortfolioReadCtx, positionId?: string) {
  const wallet = await getAuthedWallet(ctx)
  if (!wallet) return { walletRequired: true as const, message: ASK_AI_WALLET_REQUIRED }
  const positions = await ctx.db
    .query("positions")
    .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
    .collect()
  const selected = positionId ? positions.find((position) => position._id === positionId) : undefined
  if (positionId && !selected) throw new Error("Position not found")
  const relevant = selected ? [selected] : positions.filter((position) => position.status === "open")
  const engine = await readAskAIEngineSnapshot(ctx, { multiplyShockPct: -20 })
  // Raw position docs carry usd6 STRINGS and a health factor that can be the literal
  // "infinity", beside already-decoded numbers in `engine`. Decode here so the model never
  // converts money units itself.
  const decoded = relevant.map((position) => {
    const usd6 = (value: string | undefined) => Number(value ?? "0") / 1_000_000
    const collateralValueUsd = position.collateralValueUsd ?? usd6(position.collateralValueUsd6)
    const collateralAmount = position.collateralAmount ?? 0
    const liquidationPrice = position.liquidationPrice ?? null
    const collateralPriceUsd = collateralAmount > 0 ? collateralValueUsd / collateralAmount : 0
    const debtValueUsd = position.debtValueUsd ?? usd6(position.debtValueUsd6)
    return {
      positionId: position._id,
      product: position.product,
      marketSlug: position.marketSlug,
      assetId: position.assetId ?? null,
      status: position.status,
      collateralValueUsd,
      debtValueUsd,
      suppliedUsd: usd6(position.suppliedUsd6),
      earnedUsd: usd6(position.earnedUsd6),
      ltv: position.ltv ?? null,
      multiplier: position.multiplier ?? null,
      netApyPct:
        position.product === "multiply"
          ? catalogMultiplyNetApyPct(position.marketSlug, collateralValueUsd, debtValueUsd)
          : (position.netApyPct ?? null),
      supplyApyPct: position.supplyApyPct ?? null,
      liquidationPrice,
      // "How far can ETH fall before I'm liquidated?" as a fraction of price.
      priceDropToLiquidationPct: calculatePriceDropToLiquidationPct(liquidationPrice, collateralPriceUsd),
      ...askAIHealthFactorValue(position.healthFactor),
      openedAt: position.openedAt,
      lastUpdatedAt: position.lastUpdatedAt,
    }
  })
  const headrooms = decoded
    .map((position) => position.healthFactorHeadroom)
    .filter((value): value is number => typeof value === "number")
  return {
    walletRequired: false as const,
    dataProvenance: ASK_AI_DATA_PROVENANCE,
    wallet,
    // One answer for "am I safe?" across everything the wallet holds.
    riskSummary: {
      positionCount: decoded.length,
      weakestHealthFactor: headrooms.length ? Math.min(...headrooms) + 1 : null,
      weakestHeadroom: headrooms.length ? Math.min(...headrooms) : null,
      riskLevel: askAIRiskLevel(headrooms.length ? Math.min(...headrooms) + 1 : null),
      liquidatableNow: decoded.some((position) => position.riskLevel === "critical"),
      smallestPriceDropToLiquidationPct: (() => {
        const drops = decoded
          .map((position) => position.priceDropToLiquidationPct)
          .filter((value): value is number => typeof value === "number" && value >= 0)
        return drops.length ? Math.min(...drops) : null
      })(),
    },
    positions: decoded,
    engine,
    asOf: engine.asOf,
  }
}

export const positionRisk = query({
  args: { positionId: v.optional(v.string()) },
  handler: async (ctx, { positionId }) => readAskAIPositionRisk(ctx, positionId),
})

export const positionRiskForTurn = internalQuery({
  args: { turnId: v.id("askAITurns"), positionId: v.optional(v.string()) },
  handler: async (ctx, { turnId, positionId }) =>
    readAskAIPositionRisk(withTurnWallet(ctx, await readRunningTurnWallet(ctx, turnId)), positionId),
})

const simulateBorrowArgs = {
  positionId: v.string(),
  additionalBorrowAmount: v.number(),
  borrowAsset: v.string(),
  /** Window for the interest projection ("what will this cost me over a year"). */
  projectionDays: v.optional(v.number()),
}

async function readAskAISimulateBorrow(
  ctx: PortfolioReadCtx,
  {
    positionId,
    additionalBorrowAmount,
    borrowAsset,
    projectionDays,
  }: {
    positionId: string
    additionalBorrowAmount: number
    borrowAsset: string
    projectionDays?: number
  },
) {
  if (!Number.isFinite(additionalBorrowAmount) || additionalBorrowAmount <= 0 || additionalBorrowAmount > 1_000_000_000)
    throw new Error("Additional borrow amount is invalid")
  const wallet = await getAuthedWallet(ctx)
  if (!wallet) return { walletRequired: true as const, message: ASK_AI_WALLET_REQUIRED }
  const positions = await ctx.db
    .query("positions")
    .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
    .collect()
  const position = positions.find((row) => row._id === positionId && row.status === "open")
  if (!position) throw new Error("Position not found")
  const market = await ctx.db
    .query("borrowMarkets")
    .withIndex("by_slug", (q) => q.eq("slug", position.marketSlug))
    .unique()
  if (!market?.maxLtvPct) throw new Error("Position risk parameters are unavailable")
  const collateralValueUsd = position.collateralValueUsd ?? Number(position.collateralValueUsd6 ?? "0") / 1_000_000
  const debtValueUsd = position.debtValueUsd ?? Number(position.debtValueUsd6 ?? "0") / 1_000_000
  // The borrow rate lives on the pool, not on borrowMarkets.
  const pool = await ctx.db
    .query("pools")
    .withIndex("by_slug", (q) => q.eq("slug", position.marketSlug))
    .unique()
  const simulation = calculateAskAIBorrowSimulation({
    collateralValueUsd,
    debtValueUsd,
    additionalBorrowAmountUsd: additionalBorrowAmount,
    maxLtvPct: market.maxLtvPct,
  })
  const days = Math.min(Math.max(projectionDays ?? 365, 1), 3_650)
  const totalInterest =
    typeof pool?.pairAprPct === "number"
      ? calculateBorrowProjection({
          debtUsd: simulation.projected.debtValueUsd,
          borrowAprPct: pool.pairAprPct,
          days,
        })
      : null
  const incrementalInterest =
    typeof pool?.pairAprPct === "number"
      ? calculateBorrowProjection({ debtUsd: additionalBorrowAmount, borrowAprPct: pool.pairAprPct, days })
      : null
  return {
    walletRequired: false as const,
    dataProvenance: ASK_AI_DATA_PROVENANCE,
    positionId,
    borrowAsset: borrowAsset.trim().toUpperCase(),
    additionalBorrowAmount,
    simulation,
    interestProjection: totalInterest
      ? {
          borrowAprPct: totalInterest.borrowAprPct,
          days: totalInterest.days,
          // Keep the legacy field for callers that already consume it; the
          // explicit names below remove the ambiguity for Ask AI answers.
          projectedInterestUsd: totalInterest.projectedInterestUsd,
          totalProjectedInterestUsd: totalInterest.projectedInterestUsd,
          incrementalInterestUsd: incrementalInterest?.projectedInterestUsd ?? null,
          onDebtUsd: simulation.projected.debtValueUsd,
          onAdditionalBorrowUsd: additionalBorrowAmount,
        }
      : { unavailableReason: "No borrow rate is published for this market", days },
    asOf: position.lastUpdatedAt,
  }
}

export const simulateBorrow = query({
  args: simulateBorrowArgs,
  handler: readAskAISimulateBorrow,
})

export const simulateBorrowForTurn = internalQuery({
  args: { turnId: v.id("askAITurns"), ...simulateBorrowArgs },
  handler: async (ctx, { turnId, ...args }) =>
    readAskAISimulateBorrow(withTurnWallet(ctx, await readRunningTurnWallet(ctx, turnId)), args),
})

const stressPositionArgs = {
  positionId: v.string(),
  assetPriceChanges: v.array(v.object({ symbol: v.string(), change: v.number() })),
}

async function readAskAIStressPosition(
  ctx: PortfolioReadCtx,
  {
    positionId,
    assetPriceChanges,
  }: { positionId: string; assetPriceChanges: Array<{ symbol: string; change: number }> },
) {
  if (assetPriceChanges.length < 1 || assetPriceChanges.length > 8)
    throw new Error("Provide 1 to 8 asset price changes")
  for (const item of assetPriceChanges)
    if (!Number.isFinite(item.change) || item.change < -0.95 || item.change > 1)
      throw new Error("Asset price change must be between -0.95 and 1")
  const wallet = await getAuthedWallet(ctx)
  if (!wallet) return { walletRequired: true as const, message: ASK_AI_WALLET_REQUIRED }
  const positions = await ctx.db
    .query("positions")
    .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
    .collect()
  const position = positions.find((row) => row._id === positionId && row.status === "open")
  if (!position) throw new Error("Position not found")
  const market = await ctx.db
    .query("markets")
    .withIndex("by_slug", (q) => q.eq("slug", position.marketSlug))
    .first()
  const parameter = position.assetId
    ? await ctx.db
        .query("multiplyTokenParameters")
        .withIndex("by_symbol", (q) => q.eq("symbol", position.assetId!))
        .unique()
    : null
  const constituents = market?.constituents ?? (position.assetId ? [{ symbol: position.assetId, weight: 1 }] : [])
  const liquidationThresholdPct = parameter?.liquidationThresholdPct
  if (constituents.length === 0 || liquidationThresholdPct === undefined)
    throw new Error("Position risk parameters are unavailable")
  return {
    walletRequired: false as const,
    dataProvenance: ASK_AI_DATA_PROVENANCE,
    positionId,
    simulation: calculateAskAICollateralStress({
      collateralValueUsd: position.collateralValueUsd ?? Number(position.collateralValueUsd6 ?? "0") / 1_000_000,
      debtValueUsd: position.debtValueUsd ?? Number(position.debtValueUsd6 ?? "0") / 1_000_000,
      liquidationThresholdPct,
      constituents,
      assetPriceChanges: Object.fromEntries(
        assetPriceChanges.map(({ symbol, change }) => [symbol.toUpperCase(), change]),
      ),
    }),
    asOf: position.lastUpdatedAt,
  }
}

export const stressPosition = query({
  args: stressPositionArgs,
  handler: readAskAIStressPosition,
})

export const stressPositionForTurn = internalQuery({
  args: { turnId: v.id("askAITurns"), ...stressPositionArgs },
  handler: async (ctx, { turnId, ...args }) =>
    readAskAIStressPosition(withTurnWallet(ctx, await readRunningTurnWallet(ctx, turnId)), args),
})

export async function readAskAIMarketSnapshots(
  ctx: Pick<QueryCtx | MutationCtx, "db">,
  {
    sources,
    kind,
    limit,
  }: {
    sources?: AskAIMarketSource[]
    kind?: "token_price" | "dex_pool" | "lending_market"
    limit?: number
  },
) {
  const boundedLimit = Math.min(Math.max(limit ?? 10, 1), 50)
  const rows = sources
    ? (
        await Promise.all(
          sources.map((source) =>
            kind
              ? ctx.db
                  .query("askAIMarketSnapshots")
                  .withIndex("by_source_kind_key", (q) => q.eq("source", source).eq("kind", kind))
                  .take(boundedLimit)
              : ctx.db
                  .query("askAIMarketSnapshots")
                  .withIndex("by_source_kind_key", (q) => q.eq("source", source))
                  .take(boundedLimit),
          ),
        )
      ).flat()
    : await ctx.db.query("askAIMarketSnapshots").withIndex("by_fetched_at").order("desc").take(boundedLimit)
  return rows
    .filter((row) => !kind || row.kind === kind)
    .filter((row) => marketFreshness(row.kind, row.sourceUpdatedAt ?? row.fetchedAt, Date.now()) === "fresh")
    .sort((left, right) => right.fetchedAt - left.fetchedAt)
    .slice(0, boundedLimit)
}

export const marketSnapshots = query({
  args: {
    sources: v.optional(v.array(v.union(v.literal("coingecko"), v.literal("defillama"), v.literal("aave")))),
    kind: v.optional(v.union(v.literal("token_price"), v.literal("dex_pool"), v.literal("lending_market"))),
    limit: v.optional(v.number()),
  },
  handler: readAskAIMarketSnapshots,
})

export function marketFreshness(kind: "token_price" | "dex_pool" | "lending_market", at: number, now = Date.now()) {
  const threshold =
    kind === "dex_pool"
      ? ASK_AI_CONFIG.freshness.poolMetricsStaleAfterMs
      : kind === "lending_market"
        ? ASK_AI_CONFIG.freshness.aaveMarketStaleAfterMs
        : ASK_AI_CONFIG.freshness.tokenPriceStaleAfterMs
  return now - at <= threshold ? ("fresh" as const) : ("stale" as const)
}

// Filler words that match everything ("on" is a substring of many payloads) and drown out the
// meaningful terms in a natural question.
const ASK_AI_SEARCH_STOPWORDS = new Set([
  "the",
  "is",
  "are",
  "was",
  "on",
  "in",
  "of",
  "to",
  "for",
  "and",
  "or",
  "a",
  "an",
  "what",
  "whats",
  "which",
  "best",
  "top",
  "highest",
  "biggest",
  "largest",
  "good",
  "great",
  "show",
  "me",
  "my",
  "our",
  "i",
  "do",
  "does",
  "how",
  "now",
  "current",
  "currently",
  "price",
  "prices",
  "rate",
  "rates",
  "market",
  "markets",
  "pool",
  "pools",
  "token",
  "tokens",
  "asset",
  "assets",
])

const ASK_AI_SEARCH_TERM_ALIASES = new Map([
  ["bitcoin", "btc"],
  ["ethereum", "eth"],
  ["chainlink", "link"],
  ["uniswap", "uni"],
  ["arbitrum", "arb"],
  ["optimism", "op"],
  ["aerodrome", "aero"],
  ["curve", "crv"],
  ["tether", "usdt"],
])

const ASK_AI_PRICE_SYMBOLS = new Set([
  "aave",
  "aero",
  "arb",
  "bal",
  "btc",
  "cbbtc",
  "cbeth",
  "crv",
  "crvusd",
  "dai",
  "eth",
  "eurc",
  "frxusd",
  "gho",
  "gno",
  "ldo",
  "link",
  "op",
  "reth",
  "rlusd",
  "steth",
  "uni",
  "usdc",
  "usde",
  "usdg",
  "usdt",
  "wbtc",
  "weeth",
  "weth",
  "wsteth",
])

const ASK_AI_PRICE_TERM_SYMBOLS = new Map<string, string[]>([
  ["btc", ["btc", "wbtc", "cbbtc"]],
  ["eth", ["eth", "weth", "steth", "wsteth", "reth", "weeth", "cbeth"]],
])

// Match on the payload's project/symbol/chain: the snapshot `key` is often an opaque hash
// ("defillama:0x…"), so key+source alone never finds a pool by name.
function askAISnapshotHaystack(snapshot: { source: string; kind: string; key: string; payload: unknown }): string {
  const payload = (snapshot.payload ?? {}) as Record<string, unknown>
  const fields = [
    snapshot.source,
    snapshot.kind,
    snapshot.key,
    payload.symbol,
    payload.project,
    payload.chain,
    payload.market,
    payload.name,
    payload.id,
  ]
  return fields
    .filter((value) => typeof value === "string")
    .join(" ")
    .toLowerCase()
}

// Rank magnitude so "best/top/largest" surfaces the deepest markets first.
function askAISnapshotSize(payload: unknown): number {
  const row = (payload ?? {}) as Record<string, unknown>
  const candidate = row.tvlUsd ?? row.totalValueLockedUSD ?? row.sizeUsd ?? row.availableLiquidity
  return typeof candidate === "number" && Number.isFinite(candidate) ? candidate : 0
}

function finiteMarketNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined
}

function compactMarketData(kind: "token_price" | "dex_pool" | "lending_market", payload: unknown) {
  const row = (payload ?? {}) as Record<string, unknown>
  const fields: Record<string, unknown> =
    kind === "token_price"
      ? {
          symbol: row.symbol,
          priceUsd: finiteMarketNumber(row.price) ?? finiteMarketNumber(row.priceUsd) ?? finiteMarketNumber(row.usd),
          confidence: finiteMarketNumber(row.confidence),
          status: row.status,
        }
      : kind === "dex_pool"
        ? {
            pool: row.pool ?? row.id,
            project: row.project,
            chain: row.chain,
            symbol: row.symbol,
            tvlUsd:
              finiteMarketNumber(row.tvlUsd) ??
              finiteMarketNumber(row.totalValueLockedUSD) ??
              finiteMarketNumber(row.liquidityUsd),
            volume24hUsd: finiteMarketNumber(row.volume24hUsd) ?? finiteMarketNumber(row.volume24h),
            apyPct: finiteMarketNumber(row.apy),
          }
        : {
            market: row.market,
            chainId: row.chainId,
            version: row.version,
            maxLtvPct: finiteMarketNumber(row.maxLtvPct),
            liquidationThresholdPct: finiteMarketNumber(row.liquidationThresholdPct),
            supplyCap: finiteMarketNumber(row.supplyCap),
            borrowCap: finiteMarketNumber(row.borrowCap),
            eModes: row.eModes,
            canSupply: row.canSupply,
            canBorrow: row.canBorrow,
            isFrozen: row.isFrozen,
            isPaused: row.isPaused,
            supplyCapReached: row.supplyCapReached,
            borrowCapReached: row.borrowCapReached,
            symbol: row.symbol,
            name: row.name,
            sizeUsd: finiteMarketNumber(row.sizeUsd),
            supplyApyPct: finiteMarketNumber(row.supplyApyPct),
            borrowApyPct: finiteMarketNumber(row.variableBorrowRate),
            utilizationPct: finiteMarketNumber(row.utilizationRate),
            availableLiquidityUsd: finiteMarketNumber(row.availableLiquidity),
          }
  return Object.fromEntries(Object.entries(fields).filter(([, value]) => value !== undefined))
}

export const searchMarkets = query({
  args: { query: v.string(), limit: v.optional(v.number()) },
  handler: async (ctx, { query: rawQuery, limit }) => {
    const queryText = rawQuery.trim().toLowerCase()
    if (!queryText || queryText.length > 200) throw new Error("Market query must contain 1 to 200 characters")
    const boundedLimit = Math.min(Math.max(limit ?? 10, 1), 20)
    const terms = queryText.split(/[^\p{L}\p{N}]+/u).filter(Boolean)
    // Drop filler words so "best ETH pools on Uniswap" matches "eth"/"uniswap", falling back
    // to the raw terms when the query is entirely stopwords.
    const meaningfulTerms = terms.filter((term) => term.length >= 3 && !ASK_AI_SEARCH_STOPWORDS.has(term))
    const searchTerms = (meaningfulTerms.length > 0 ? meaningfulTerms : terms).map(
      (term) => ASK_AI_SEARCH_TERM_ALIASES.get(term) ?? term,
    )
    // Bias the ranking by question kind, so a "pools" question surfaces pools and a "price"
    // question token prices even when both match the same asset term.
    const wantsPools = /\b(pool|pools|liquidity|tvl|lp)\b/.test(queryText)
    const wantsYield = /\b(yield|yields|apr|apy|rate|rates|lend|lending|supply|borrow)\b/.test(queryText)
    const wantsPrice = /\b(price|prices|worth|cost|value|quote)\b/.test(queryText)
    const wantsAaveProtocol =
      /\b(?:on|from|at)\s+aave\b/.test(queryText) ||
      /\baave(?:\s+v[34])?\s+(?:lend|lending|market|markets|pool|pools|apy|apr|rate|rates)\b/.test(queryText)
    const wantsAvanaOnly = /\bavana\b/.test(queryText) && !/\b(aave|compare|versus|vs)\b/.test(queryText)
    const wantsAaveOnly = /\baave\b/.test(queryText) && !wantsPrice && !/\b(avana|compare|versus|vs)\b/.test(queryText)
    const minimumYieldMatch = queryText.match(
      /\b(?:at least|above|over|more than|minimum(?: of)?)\s+(\d+(?:\.\d+)?)\s*%/,
    )
    const minimumYieldPct = minimumYieldMatch ? Number(minimumYieldMatch[1]) : null
    const kindBoost = (kind: "token_price" | "dex_pool" | "lending_market") =>
      (wantsPools && kind === "dex_pool" ? 2 : wantsPools && kind === "lending_market" ? 1 : 0) +
      (wantsYield && kind === "lending_market" ? 2 : wantsYield && kind === "dex_pool" ? 1 : 0) +
      (wantsPrice && kind === "token_price" ? 1 : 0)

    // Price questions are the highest-volume Ask AI read, so resolve ONLY the symbols named in
    // the prompt through indexes — collecting every price and history point per request does
    // not stay O(symbols requested) as the cache grows.
    const requestedSymbols = [
      ...new Set(
        searchTerms
          .filter((term) => ASK_AI_PRICE_SYMBOLS.has(term))
          .flatMap((term) => ASK_AI_PRICE_TERM_SYMBOLS.get(term) ?? [term])
          .slice(0, boundedLimit),
      ),
    ]
    const tokenPrices = (
      await Promise.all(
        requestedSymbols.map((symbol) =>
          ctx.db
            .query("tokenPrices")
            .withIndex("by_symbol", (q) => q.eq("symbol", symbol))
            .unique(),
        ),
      )
    ).filter((price): price is NonNullable<typeof price> => Boolean(price))
    const historyRows = await Promise.all(
      tokenPrices.map(async (price) => ({
        symbol: price.symbol,
        rows: await ctx.db
          .query("tokenPricesHistory")
          .withIndex("by_symbol_day", (q) => q.eq("symbol", price.symbol))
          .order("desc")
          .take(90),
      })),
    )
    const historyBySymbol = new Map(
      historyRows.map(({ symbol, rows }) => [
        symbol,
        rows.map((point) => ({ day: point.day, priceUsd: point.priceUsd })).sort((a, b) => a.day.localeCompare(b.day)),
      ]),
    )

    // The 90 days fetched above are stripped from the model context (askAIAgent.ts compacts
    // provider rows), so derive the moves here rather than shipping the raw series.
    const priceChangePct = (history: ReadonlyArray<{ priceUsd: number }>, daysBack: number, current: number) => {
      if (!Number.isFinite(current) || current <= 0 || history.length === 0) return undefined
      const past = history[history.length - 1 - daysBack]?.priceUsd
      return typeof past === "number" && past > 0 ? ((current - past) / past) * 100 : undefined
    }
    const scoredPrices = tokenPrices
      .filter((price) => price.status !== "invalid")
      .map((price) => {
        const haystack = price.symbol.toLowerCase()
        const matched = searchTerms.filter((term) => haystack.includes(term)).length
        const history = historyBySymbol.get(price.symbol) ?? []
        const changes = {
          change24hPct: priceChangePct(history, 1, price.priceUsd),
          change7dPct: priceChangePct(history, 7, price.priceUsd),
          change30dPct: priceChangePct(history, 30, price.priceUsd),
        }
        return {
          matched,
          exact: searchTerms.includes(haystack) ? 1 : 0,
          boost: kindBoost("token_price"),
          size: 0,
          row: {
            source: "defillama" as const,
            kind: "token_price" as const,
            key: price.symbol,
            data: {
              ...compactMarketData("token_price", {
                symbol: price.symbol,
                priceUsd: price.priceUsd,
                confidence: price.confidence,
                status: price.status,
              }),
              ...Object.fromEntries(Object.entries(changes).filter(([, value]) => value !== undefined)),
            },
            history,
            asOf: price.sourceUpdatedAt ?? price.updatedAt,
            freshness: price.status === "fresh" ? ("fresh" as const) : ("stale" as const),
          },
        }
      })
      .filter((entry) => entry.matched > 0)

    if (wantsPrice && scoredPrices.length > 0) {
      return {
        markets: [],
        providerData: scoredPrices
          .sort((a, b) => b.matched - a.matched || b.exact - a.exact)
          .slice(0, boundedLimit)
          .map((entry) => entry.row),
      }
    }

    const [marketCache, snapshots] = await Promise.all([
      ctx.db
        .query("marketSnapshotsCache")
        .withIndex("by_singleton", (q) => q.eq("singleton", "markets"))
        .first(),
      wantsAaveOnly
        ? ctx.db
            .query("askAIMarketSnapshots")
            .withIndex("by_source_kind_key", (q) => q.eq("source", "aave"))
            .take(1500)
        : wantsPools && !wantsYield
          ? ctx.db
              .query("askAIMarketSnapshots")
              .withIndex("by_source_kind_key", (q) => q.eq("source", "defillama").eq("kind", "dex_pool"))
              .take(250)
          : ctx.db.query("askAIMarketSnapshots").withIndex("by_fetched_at").order("desc").take(250),
    ])
    // Bounded cold fallback for tests and a brand-new deployment; production reads the singleton.
    const markets = marketCache?.rows ?? (await ctx.db.query("markets").take(200))
    const matchingMarkets = (wantsAaveProtocol || wantsAaveOnly ? [] : markets)
      .filter((market) => {
        const haystack = `${market.slug} ${market.name} ${market.symbol} ${market.venueLabel ?? ""}`.toLowerCase()
        return searchTerms.some((term) => haystack.includes(term))
      })
      .slice(0, boundedLimit)

    // Score canonical prices and cached snapshots on the SAME scale before ranking, or token
    // prices (added first) crowd out deep pools.
    const scoredSnapshots = (wantsAvanaOnly ? [] : snapshots)
      .filter((snapshot) => marketFreshness(snapshot.kind, snapshot.sourceUpdatedAt ?? snapshot.fetchedAt) === "fresh")
      .map((snapshot) => {
        const haystack = askAISnapshotHaystack(snapshot)
        const matched = searchTerms.filter((term) => haystack.includes(term)).length
        const data = compactMarketData(snapshot.kind, snapshot.payload)
        const symbol = typeof data.symbol === "string" ? data.symbol.toLowerCase() : ""
        return {
          matched,
          exact: symbol.length > 0 && searchTerms.includes(symbol) ? 1 : 0,
          boost: kindBoost(snapshot.kind),
          size: askAISnapshotSize(snapshot.payload),
          row: {
            source: snapshot.source,
            kind: snapshot.kind,
            key: snapshot.key,
            data,
            asOf: snapshot.sourceUpdatedAt ?? snapshot.fetchedAt,
            freshness: marketFreshness(snapshot.kind, snapshot.sourceUpdatedAt ?? snapshot.fetchedAt),
          },
          yieldPct:
            typeof data.supplyApyPct === "number"
              ? data.supplyApyPct
              : typeof data.apyPct === "number"
                ? data.apyPct
                : Number.NEGATIVE_INFINITY,
        }
      })
      .filter(
        (entry) =>
          entry.matched > 0 &&
          (!wantsAaveProtocol || entry.row.source === "aave") &&
          (!wantsYield || entry.row.kind === "lending_market" || entry.row.kind === "dex_pool"),
      )

    const providerData = [...scoredPrices, ...scoredSnapshots]
      // Most query terms matched, then the kind the question asked for, then depth.
      .sort((a, b) => {
        if (minimumYieldPct !== null && "yieldPct" in a && "yieldPct" in b) {
          const aMeets = a.yieldPct >= minimumYieldPct
          const bMeets = b.yieldPct >= minimumYieldPct
          if (aMeets !== bMeets) return aMeets ? -1 : 1
          if (a.yieldPct !== b.yieldPct) return b.yieldPct - a.yieldPct
        }
        return b.matched - a.matched || b.boost - a.boost || b.exact - a.exact || b.size - a.size
      })
      .slice(0, boundedLimit)
      .map((entry) => entry.row)

    return { markets: matchingMarkets, providerData }
  },
})

export const poolMetrics = query({
  args: { marketId: v.string() },
  handler: async (ctx, { marketId }) => {
    const normalizedId = marketId.trim().toLowerCase()
    if (!normalizedId || normalizedId.length > 160) throw new Error("Market ID is invalid")
    const snapshots = await ctx.db.query("askAIMarketSnapshots").withIndex("by_fetched_at").order("desc").take(100)
    // Slug is a lowercase URL-safe id, so the common case is a point read; symbols are
    // typically upper-case, so they need the second lookup.
    const market =
      (await ctx.db
        .query("markets")
        .withIndex("by_slug", (q) => q.eq("slug", normalizedId))
        .first()) ??
      (await ctx.db
        .query("markets")
        .withIndex("by_symbol", (q) => q.eq("symbol", normalizedId.toUpperCase()))
        .first())
    const aliases = new Set([normalizedId, market?.slug.toLowerCase(), market?.symbol.toLowerCase()].filter(Boolean))
    const providerData = snapshots
      .filter((snapshot) => snapshot.kind === "dex_pool" && aliases.has(snapshot.key.toLowerCase()))
      .filter((snapshot) => marketFreshness("dex_pool", snapshot.sourceUpdatedAt ?? snapshot.fetchedAt) === "fresh")
      .map((snapshot) => ({
        source: snapshot.source,
        data: snapshot.payload,
        asOf: snapshot.sourceUpdatedAt ?? snapshot.fetchedAt,
        freshness: marketFreshness("dex_pool", snapshot.sourceUpdatedAt ?? snapshot.fetchedAt),
      }))
    if (!market && providerData.length === 0) throw new Error("Market not found")
    return { market: market ?? null, providerData }
  },
})
