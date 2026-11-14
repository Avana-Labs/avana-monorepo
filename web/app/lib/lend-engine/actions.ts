import { calculateAvailableLiquidity, calculateUtilization } from "./formulas"
import { simulateDeposit, simulateWithdraw } from "./simulation"
import type {
  LendAction,
  LendClaimRewardsIntent,
  LendDepositIntent,
  LendPosition,
  LendSystemState,
  LendWithdrawIntent,
} from "./types"

// A remainder worth less than this after a withdraw is dust (ongoing accrual
// between quote and execution): sweep it out and close the position rather than
// leaving a zombie ~$0 "active" row on the dashboard.
const DUST_REMAINDER_USD = 0.01

function findWalletPosition(state: LendSystemState, walletId: string, marketId: string): LendPosition | undefined {
  return Object.values(state.positions).find(
    (position) => position.walletId === walletId && position.marketId === marketId && position.status === "active",
  )
}

function readWalletBalance(state: LendSystemState, walletId: string, marketId: string) {
  return state.walletBalances[walletId]?.[marketId] ?? 0
}

function writeWalletBalance(state: LendSystemState, walletId: string, marketId: string, nextBalance: number) {
  return {
    ...state.walletBalances,
    [walletId]: {
      ...(state.walletBalances[walletId] ?? {}),
      [marketId]: Math.max(0, nextBalance),
    },
  }
}

function updateMarketTotals(market: LendSystemState["markets"][string], deltaSupplied: number) {
  const totalSupplied = Math.max(0, market.totalSupplied + deltaSupplied)
  const availableLiquidity = calculateAvailableLiquidity(totalSupplied, market.totalBorrowed)
  return {
    ...market,
    totalSupplied,
    availableLiquidity,
    utilization: calculateUtilization(market.totalBorrowed, totalSupplied),
  }
}

export function applyLendAction(
  state: LendSystemState,
  action: LendAction,
  ids: { positionId: string; transactionId: string },
): LendSystemState {
  const now = action.at ?? state.now
  if (action.type === "deposit") {
    return applyDeposit(state, action, now, ids)
  }
  if (action.type === "claim") {
    return applyClaimRewards(state, action, now, ids)
  }
  return applyWithdraw(state, action, now, ids)
}

function applyDeposit(
  state: LendSystemState,
  action: LendDepositIntent,
  now: number,
  ids: { positionId: string; transactionId: string },
): LendSystemState {
  if (!Number.isFinite(action.depositAmount) || action.depositAmount <= 0) return state
  const market = state.markets[action.marketId]
  if (!market) return state
  const existing = findWalletPosition(state, action.walletId, action.marketId)
  const simulation = simulateDeposit({
    market,
    position: existing,
    depositAmount: action.depositAmount,
    walletBalance: action.walletBalance,
    now,
  })
  if (!simulation.validation.allowed) return state

  const updatedMarket = updateMarketTotals(
    {
      ...market,
      liquidityIndex: simulation.after.liquidityIndex,
      lastAccrualTimestamp: now,
    },
    action.depositAmount,
  )

  const positionId = existing?.positionId ?? ids.positionId
  const position: LendPosition = {
    positionId,
    walletId: action.walletId,
    marketId: action.marketId,
    asset: market.asset.symbol,
    principalAmount: simulation.after.principalAmount,
    scaledBalance: simulation.after.scaledBalance,
    liquidityIndexAtLastAction: simulation.after.liquidityIndex,
    currentSuppliedAmount: simulation.after.suppliedAmount,
    interestEarned: simulation.after.interestEarned,
    rewardsEarnedUsd: simulation.after.rewardsEarnedUsd,
    suppliedValueUsd: simulation.after.suppliedValueUsd,
    openedAt: existing?.openedAt ?? now,
    updatedAt: now,
    status: simulation.after.suppliedAmount > 0 ? "active" : "closed",
  }

  return {
    now,
    markets: { ...state.markets, [action.marketId]: updatedMarket },
    positions: { ...state.positions, [positionId]: position },
    walletBalances: writeWalletBalance(
      state,
      action.walletId,
      action.marketId,
      readWalletBalance(state, action.walletId, action.marketId) - action.depositAmount,
    ),
    transactions: [
      ...state.transactions,
      {
        id: ids.transactionId,
        walletId: action.walletId,
        marketId: action.marketId,
        kind: "deposit",
        asset: market.asset.symbol,
        amount: action.depositAmount,
        at: now,
      },
    ],
  }
}

function applyWithdraw(
  state: LendSystemState,
  action: LendWithdrawIntent,
  now: number,
  ids: { positionId: string; transactionId: string },
): LendSystemState {
  if (!Number.isFinite(action.withdrawAmount) || action.withdrawAmount <= 0) return state
  const market = state.markets[action.marketId]
  const position = state.positions[action.positionId]
  if (!market || !position) return state

  const simulation = simulateWithdraw({
    market,
    position,
    withdrawAmount: action.withdrawAmount,
    now,
  })
  if (!simulation.validation.allowed) return state

  // A "withdraw max" quote can leave a tiny remainder because the position keeps
  // accruing between quote and execution. If what's left is dust (sub-cent),
  // close the position and sweep the remainder into this withdraw so no zombie
  // $0 "active" row lingers and the accrued interest is fully paid out.
  const remainderIsDust =
    simulation.after.suppliedAmount <= 1e-12 || simulation.after.suppliedValueUsd < DUST_REMAINDER_USD
  const withdrawnAmount = remainderIsDust
    ? action.withdrawAmount + simulation.after.suppliedAmount
    : action.withdrawAmount

  const updatedMarket = updateMarketTotals(
    {
      ...market,
      liquidityIndex: simulation.after.liquidityIndex,
      lastAccrualTimestamp: now,
    },
    -withdrawnAmount,
  )

  const updatedPosition: LendPosition = remainderIsDust
    ? {
        ...position,
        principalAmount: 0,
        scaledBalance: 0,
        liquidityIndexAtLastAction: simulation.after.liquidityIndex,
        currentSuppliedAmount: 0,
        interestEarned: 0,
        rewardsEarnedUsd: simulation.after.rewardsEarnedUsd,
        suppliedValueUsd: 0,
        updatedAt: now,
        status: "closed",
      }
    : {
        ...position,
        principalAmount: simulation.after.principalAmount,
        scaledBalance: simulation.after.scaledBalance,
        liquidityIndexAtLastAction: simulation.after.liquidityIndex,
        currentSuppliedAmount: simulation.after.suppliedAmount,
        interestEarned: simulation.after.interestEarned,
        rewardsEarnedUsd: simulation.after.rewardsEarnedUsd,
        suppliedValueUsd: simulation.after.suppliedValueUsd,
        updatedAt: now,
        status: "active",
      }

  return {
    now,
    markets: { ...state.markets, [action.marketId]: updatedMarket },
    positions: { ...state.positions, [action.positionId]: updatedPosition },
    walletBalances: writeWalletBalance(
      state,
      action.walletId,
      action.marketId,
      readWalletBalance(state, action.walletId, action.marketId) + withdrawnAmount,
    ),
    transactions: [
      ...state.transactions,
      {
        id: ids.transactionId,
        walletId: action.walletId,
        marketId: action.marketId,
        kind: "withdraw",
        asset: market.asset.symbol,
        amount: withdrawnAmount,
        at: now,
      },
    ],
  }
}

function applyClaimRewards(
  state: LendSystemState,
  action: LendClaimRewardsIntent,
  now: number,
  ids: { positionId: string; transactionId: string },
): LendSystemState {
  const walletPositions = Object.entries(state.positions).filter(
    ([, position]) => position.walletId === action.walletId,
  )
  const claimableUsd = walletPositions.reduce((sum, [, position]) => sum + position.rewardsEarnedUsd, 0)
  if (claimableUsd <= 0) return state

  const nextPositions: LendSystemState["positions"] = {}
  for (const [positionId, position] of Object.entries(state.positions)) {
    if (position.walletId !== action.walletId) {
      nextPositions[positionId] = position
      continue
    }
    nextPositions[positionId] = {
      ...position,
      rewardsEarnedUsd: 0,
      updatedAt: now,
    }
  }

  return {
    ...state,
    now,
    positions: nextPositions,
    walletBalances: state.walletBalances,
    transactions: [
      ...state.transactions,
      {
        id: ids.transactionId,
        walletId: action.walletId,
        marketId: "rewards",
        kind: "claim",
        asset: "Rewards",
        amount: claimableUsd,
        at: now,
      },
    ],
  }
}
