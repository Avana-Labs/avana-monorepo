/** A CDP Spoke, keyed by the id services/convex reports for it. */
export type BorrowSpokeId = string

export type BorrowVisual = {
  symbol: string
  shortLabel: string
  iconUrl?: string | null
  bgClassName: string
  textClassName: string
}

type BorrowMetricPoint = {
  at: string
  value: bigint
}

export type BorrowMetricSeries = {
  label: string
  unit: "usd" | "pct" | "count"
  points: BorrowMetricPoint[]
}

export type BorrowFaqItem = {
  question: string
  answer: string
}

export type BorrowParameterChange = {
  date: string
  title: string
  body?: string
}

type BorrowTransactionKind = "deposit" | "withdraw" | "borrow" | "repay" | "claim" | "liquidate"

export type BorrowTransaction = {
  id: string
  walletId: string
  spokeId?: BorrowSpokeId
  marketId?: string
  assetId?: string
  kind: BorrowTransactionKind
  amountUsd6: bigint
  at: number
}

export type BorrowMarketRecord = {
  id: string
  spokeId: BorrowSpokeId
  display: {
    name: string
    lpSymbol: string
    venue: string
    chain: string
    feeTier: string
    subtitle: string
    visuals: [BorrowVisual, BorrowVisual]
  }
  riskConfig: {
    collateralFactorWad: bigint
    liquidationThresholdWad: bigint
    riskScoreWad: bigint
  }
  /** List/Explore overlay from Convex `premiumBps` when snapshots carry it. */
  listPremiumBps?: number
  /** Reserve factor as a percentage (0–100). Overlaid from Convex when the snapshot
   *  carries it; detail QuickStats prefer this over the isStablePool heuristic. */
  reserveFactorPct?: number
  relations: {
    supportedBorrowAssetIds: string[]
    relatedMarketIds: string[]
  }
  snapshot: {
    lpTokenPriceUsd6: bigint
    feeApyWad: bigint
    totalLiquidityUsd6: bigint
    totalBorrowedUsd6: bigint
    availableUsd6: bigint
    volume24hUsd6: bigint
    fees24hUsd6: bigint
    totalCollateralShares: bigint
    supplyIndexRay: bigint
  }
  detail: {
    about: string
    faqs: BorrowFaqItem[]
    parameterChanges: BorrowParameterChange[]
    governanceNotes: Array<{ title: string; body: string; tone?: "info" | "warning" | "positive" }>
  }
  analytics: {
    keyMetrics: Record<string, BorrowMetricSeries>
    cashflow: BorrowMetricSeries
    engagement: BorrowMetricSeries
  }
}

export type BorrowAssetRecord = {
  id: string
  baseAssetId: string
  spokeId: BorrowSpokeId
  marketIds: string[]
  slug: string
  contextLabel: string
  symbol: string
  display: {
    name: string
    subtitle: string
    chain: string
    category: "stable" | "eth" | "btc" | "crypto"
    visual: BorrowVisual
  }
  borrowConfig: {
    baseBorrowAprWad: bigint
  }
  /** Reserve factor as a percentage (0–100). Overlaid from Convex when the snapshot
   *  carries it; asset detail QuickStats prefer this over the catalog heuristic. */
  reserveFactorPct?: number
  snapshot: {
    priceUsd6: bigint
    priceChange24hWad: bigint
    availableLiquidityUsd6: bigint
    totalBorrowedUsd6: bigint
    totalDebtSharesUsd6: bigint
  }
  detail: {
    about: string
    faqs: BorrowFaqItem[]
  }
  analytics: {
    utilization: BorrowMetricSeries
    supplyBorrow: Record<string, BorrowMetricSeries>
  }
}

export type UserCollateralPosition = {
  id: string
  marketId: string
  collateralShares: bigint
  principalTokenAmount: bigint
  collateralEnabled: boolean
}

export type UserDebtPosition = {
  id: string
  assetId: string
  baseAssetId: string
  spokeId: BorrowSpokeId
  marketId?: string
  debtSharesUsd6: bigint
  debtIndexRay: bigint
  borrowRateWad: bigint
  principalBorrowedUsd6: bigint
  /**
   * USD6 price of the borrowed asset captured at borrow time. Lets the debt USD value be repriced
   * to the borrowed token's current spot price (§7 / D2) via the ratio currentPrice/priceAtBorrow.
   * Optional: legacy positions without it reprice as a no-op (value stays fixed-USD).
   */
  priceAtBorrowUsd6?: bigint
  /**
   * Epoch ms this debt was first borrowed (from the durable transaction ledger). Powers the
   * per-position "Interest Owed" display (debt × rate × elapsed-since-open), the way Lend accrues from
   * `openedAt` — so a loan's interest reflects its OWN age, not the account-wide engine
   * clock that any action resets. Optional: a debt with no ledgered open time shows no interest.
   */
  openedAt?: number
}

export type UserRewardPosition = {
  id: string
  marketId: string
  claimableUsd6: bigint
  earnedUsd6: bigint
}

export type BorrowAccountState = {
  walletId: string
  walletBalanceUsd6: bigint
  walletLpBalancesUsd6: Record<string, bigint>
  walletReturnedLpBalancesUsd6?: Record<string, bigint>
  interestSettledUsd6: bigint
  lastUpdatedAt: number
  collateralPositions: UserCollateralPosition[]
  debtPositions: UserDebtPosition[]
  rewardPositions: UserRewardPosition[]
}

export type BorrowAction =
  | {
      type: "borrow"
      walletId: string
      marketId: string
      assetId: string
      amountUsd6: bigint
      at?: number
    }
  | {
      type: "repay"
      walletId: string
      debtPositionId: string
      /** Borrowed asset used for activity/receipt labeling; the engine resolves the debt by ID. */
      assetId?: string
      amountUsd6: bigint
      at?: number
    }
  | {
      type: "supplyCollateral"
      walletId: string
      marketId: string
      amountUsd6: bigint
      at?: number
    }
  | {
      type: "removeCollateral"
      walletId: string
      positionId: string
      amountUsd6?: bigint
      percentBps?: number
      at?: number
    }
  | {
      type: "liquidate"
      walletId: string
      positionId: string
      debtPositionId?: string
      liquidatorWalletId?: string
      repayAmountUsd6: bigint
      at?: number
    }
  | {
      type: "claim"
      walletId: string
      rewardPositionIds: string[]
      amountUsd6: bigint
      at?: number
    }

export type BorrowSystemState = {
  now: number
  markets: Record<string, BorrowMarketRecord>
  assets: Record<string, BorrowAssetRecord>
  accounts: Record<string, BorrowAccountState>
  transactions: BorrowTransaction[]
}
