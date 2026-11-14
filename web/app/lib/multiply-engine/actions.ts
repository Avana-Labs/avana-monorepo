import { revalueMultiplyPosition, simulateDeleverage, simulateMultiply } from "./simulation"
import type { MultiplyAction, MultiplyPosition, MultiplySystemState, MultiplyTransaction } from "./types"

function cloneState(state: MultiplySystemState): MultiplySystemState {
  const markets: MultiplySystemState["markets"] = {}
  for (const [id, market] of Object.entries(state.markets)) {
    markets[id] = {
      ...market,
      economics: { ...market.economics },
      risk: { ...market.risk },
      collateralAsset: { ...market.collateralAsset },
      borrowAsset: { ...market.borrowAsset },
    }
  }

  const positions: MultiplySystemState["positions"] = {}
  for (const [id, position] of Object.entries(state.positions)) {
    positions[id] = { ...position }
  }
  const walletBalancesUsd: MultiplySystemState["walletBalancesUsd"] = {}
  for (const [walletId, balances] of Object.entries(state.walletBalancesUsd ?? {})) {
    walletBalancesUsd[walletId] = { ...balances }
  }

  return {
    ...state,
    markets,
    positions,
    walletBalancesUsd,
    transactions: [...state.transactions],
  }
}

function positionId(walletId: string, marketId: string) {
  return `${walletId}:${marketId}`
}

/**
 * The wallet's open loop on a market. Loops hydrated from Convex are keyed by their Convex id,
 * not `wallet:market`, so an id-only lookup missed every persisted loop: adding to one built a
 * fresh position that the server wrote over the real loop.
 */
function findWalletMarketPosition(state: MultiplySystemState, walletId: string, marketId: string) {
  return (
    state.positions[positionId(walletId, marketId)] ??
    Object.values(state.positions).find(
      (position) => position.walletId === walletId && position.marketId === marketId,
    ) ??
    null
  )
}

function buildPosition(params: {
  id?: string
  walletId: string
  marketId: string
  simulation: ReturnType<typeof simulateMultiply>
  now: number
  openedAt?: number
}): MultiplyPosition {
  return {
    id: params.id ?? positionId(params.walletId, params.marketId),
    walletId: params.walletId,
    marketId: params.marketId,
    collateralAmount: params.simulation.after.collateralAmount,
    collateralValueUsd: params.simulation.after.collateralValueUsd,
    debtValueUsd: params.simulation.after.debtValueUsd,
    multiplier: params.simulation.after.multiplier,
    ltv: params.simulation.after.ltv,
    healthFactor: params.simulation.after.healthFactor,
    liquidationPrice: params.simulation.after.liquidationPrice,
    netApy: params.simulation.economics.netApy,
    openedAt: params.openedAt ?? params.now,
    lastUpdatedAt: params.now,
  }
}

function applyBorrowLiquidityDelta(state: MultiplySystemState, marketId: string, debtDeltaUsd: number) {
  const market = state.markets[marketId]
  if (!market || !Number.isFinite(debtDeltaUsd) || debtDeltaUsd === 0) return
  market.economics.availableLiquidityUsd = Math.max(0, market.economics.availableLiquidityUsd - debtDeltaUsd)
}

function adjustWalletBalanceUsd(state: MultiplySystemState, walletId: string, marketId: string, deltaUsd: number) {
  if (!Number.isFinite(deltaUsd) || deltaUsd === 0) return
  const balances = (state.walletBalancesUsd[walletId] = { ...(state.walletBalancesUsd[walletId] ?? {}) })
  balances[marketId] = Math.max(0, (balances[marketId] ?? 0) + deltaUsd)
}

export function applyMultiplyAction(state: MultiplySystemState, action: MultiplyAction): MultiplySystemState {
  const next = cloneState(state)
  const at = action.at ?? state.now

  if (action.type === "multiply") {
    if (!Number.isFinite(action.collateralAmount) || action.collateralAmount <= 0) {
      throw new Error("Collateral amount must be a positive, finite number")
    }
    if (!Number.isFinite(action.selectedMultiplier) || action.selectedMultiplier < 1) {
      throw new Error("Multiplier must be a finite number of at least 1x")
    }

    const market = next.markets[action.marketId]
    if (!market) throw new Error(`Unknown market ${action.marketId}`)

    const existing = findWalletMarketPosition(next, action.walletId, action.marketId)
    const simulation = simulateMultiply({
      market,
      collateralAmount: action.collateralAmount,
      selectedMultiplier: action.selectedMultiplier,
      existingPosition: existing,
      collateralPriceOverrideUsd: action.collateralPriceUsd,
      collateralPriceStale: action.collateralPriceStale,
    })

    if (!simulation.validation.allowed) {
      throw new Error(simulation.validation.errors[0] ?? "Multiply action blocked")
    }

    const position = buildPosition({
      id: existing?.id,
      walletId: action.walletId,
      marketId: action.marketId,
      simulation,
      now: at,
      openedAt: existing?.openedAt,
    })

    next.positions[position.id] = position
    applyBorrowLiquidityDelta(next, action.marketId, simulation.after.debtValueUsd - simulation.before.debtValueUsd)
    adjustWalletBalanceUsd(
      next,
      action.walletId,
      action.marketId,
      -(action.collateralAmount * (action.collateralPriceUsd ?? market.collateralAsset.priceUsd)),
    )
    next.transactions.push({
      id: `tx-${next.transactions.length + 1}`,
      walletId: action.walletId,
      marketId: action.marketId,
      kind: "multiply",
      collateralAmountUsd: simulation.after.collateralValueUsd,
      debtDeltaUsd: simulation.after.debtValueUsd - simulation.before.debtValueUsd,
      multiplierBefore: simulation.before.multiplier,
      multiplierAfter: simulation.after.multiplier,
      at,
    } satisfies MultiplyTransaction)

    return next
  }

  if (action.type === "close") {
    const position = next.positions[action.positionId]
    if (!position) throw new Error(`Unknown position ${action.positionId}`)

    // Reprice at the live collateral price before reading it — see simulateMultiply's
    // repricedExisting. Crediting the wallet off a stale catalog price would shortchange
    // (or overpay) the cash returned on close.
    const market = next.markets[position.marketId]
    const repriced = market ? revalueMultiplyPosition(position, market, action.collateralPriceUsd) : position

    delete next.positions[position.id]
    // Repaying the outstanding debt returns that borrow capacity to the market.
    applyBorrowLiquidityDelta(next, position.marketId, -repriced.debtValueUsd)
    adjustWalletBalanceUsd(
      next,
      action.walletId,
      position.marketId,
      Math.max(0, repriced.collateralValueUsd - repriced.debtValueUsd),
    )
    next.transactions.push({
      id: `tx-${next.transactions.length + 1}`,
      walletId: action.walletId,
      marketId: position.marketId,
      kind: "close",
      collateralAmountUsd: Math.max(0, repriced.collateralValueUsd - repriced.debtValueUsd),
      debtDeltaUsd: -repriced.debtValueUsd,
      multiplierBefore: repriced.multiplier,
      multiplierAfter: 1,
      at,
    } satisfies MultiplyTransaction)

    return next
  }

  if (!Number.isFinite(action.targetMultiplier) || action.targetMultiplier < 1) {
    throw new Error("Target multiplier must be a finite number of at least 1x")
  }

  const position = next.positions[action.positionId]
  if (!position) throw new Error(`Unknown position ${action.positionId}`)

  const market = next.markets[position.marketId]
  if (!market) throw new Error(`Unknown market ${position.marketId}`)

  const simulation = simulateDeleverage({
    market,
    position,
    targetMultiplier: action.targetMultiplier,
    collateralPriceOverrideUsd: action.collateralPriceUsd,
  })

  if (!simulation.validation.allowed) {
    throw new Error(simulation.validation.errors[0] ?? "Deleverage action blocked")
  }

  const updated: MultiplyPosition = {
    ...position,
    collateralAmount: simulation.after.collateralAmount,
    collateralValueUsd: simulation.after.collateralValueUsd,
    debtValueUsd: simulation.after.debtValueUsd,
    multiplier: simulation.after.multiplier,
    ltv: simulation.after.ltv,
    healthFactor: simulation.after.healthFactor,
    liquidationPrice: simulation.after.liquidationPrice,
    netApy: simulation.economics.netApy,
    lastUpdatedAt: at,
  }

  next.positions[position.id] = updated
  applyBorrowLiquidityDelta(next, position.marketId, simulation.after.debtValueUsd - simulation.before.debtValueUsd)
  adjustWalletBalanceUsd(
    next,
    action.walletId,
    position.marketId,
    Math.max(0, simulation.before.collateralValueUsd - simulation.before.debtValueUsd) -
      Math.max(0, simulation.after.collateralValueUsd - simulation.after.debtValueUsd),
  )
  next.transactions.push({
    id: `tx-${next.transactions.length + 1}`,
    walletId: action.walletId,
    marketId: position.marketId,
    kind: "deleverage",
    collateralAmountUsd: simulation.after.collateralValueUsd,
    debtDeltaUsd: simulation.after.debtValueUsd - simulation.before.debtValueUsd,
    multiplierBefore: simulation.before.multiplier,
    multiplierAfter: simulation.after.multiplier,
    at,
  })

  return next
}
