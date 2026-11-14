import { createDataSourceAdapter } from "@/app/lib/data/core/source-runtime"
import { api } from "@/convex/_generated/api"
import { getAuthenticatedConvexClient, getAuthenticatedWallet } from "@/app/lib/data/providers/live-convex-client"
import { MULTIPLY_LIQUIDATION_THRESHOLD_FACTOR, worstMultiplyHealthFactor } from "@/app/lib/multiply-system/read-model"
import { liquidationThresholdPctFromMaxLtvPct } from "@/app/lib/borrow-system/liquidation-threshold"
import type {
  PortfolioActivityKind,
  PortfolioActivityRecord,
  PortfolioCollateralRecord,
  PortfolioDebtRecord,
  PortfolioPageRecords,
  PortfolioSupplyRecord,
} from "./records"
import type { PortfolioPageSource } from "./source"
import { allocateDebtByCollateral, calculateLiveBorrowDebt, calculateLiveMultiplyPosition } from "./live-accounting"

const livePortfolioPageAdapter = createDataSourceAdapter({
  id: "portfolio-live",
  label: "Portfolio page live source",
  mode: "live",
  supportsPagination: true,
})

export const livePortfolioPageSource: PortfolioPageSource = {
  adapter: livePortfolioPageAdapter,
  getDefaultWalletProfileId() {
    return getAuthenticatedWallet(livePortfolioPageAdapter.id, "getDefaultWalletProfileId").wallet
  },
  async getPortfolioPageRecords(walletProfileId) {
    const { client, wallet } = await getAuthenticatedConvexClient(
      livePortfolioPageAdapter.id,
      "getPortfolioPageRecords",
    )
    if (walletProfileId && walletProfileId.toLowerCase() !== wallet) {
      throw new Error("Requested portfolio does not match the authenticated wallet.")
    }

    const state = await client.query(api.sandbox.transactions.getPortfolioPageState, { wallet })
    const marketBySlug = new Map(state.markets.map((market) => [market.slug, market]))
    const poolBySlug = new Map(state.pools.map((pool) => [pool.slug, pool]))
    const toUsd = (value?: string) => Number(BigInt(value ?? "0")) / 1_000_000
    const multiplyPositions = state.positions.filter((position) => position.product === "multiply")
    const totalMultiplyCollateral = multiplyPositions.reduce(
      (sum, position) => sum + (position.collateralValueUsd ?? 0),
      0,
    )
    const totalMultiplyDebt = multiplyPositions.reduce((sum, position) => sum + (position.debtValueUsd ?? 0), 0)
    const healthFactors = multiplyPositions
      .map((position) => position.healthFactor)
      .filter((value): value is number => typeof value === "number")
    const rewardState = state.rewards
      ? (JSON.parse(state.rewards.stateJson) as { claims?: Array<{ amount: number; status: string }> })
      : null
    const claimedRewards = rewardState?.claims?.filter((claim) => claim.status === "confirmed") ?? []

    const supplies: PortfolioSupplyRecord[] = state.positions
      .filter((position) => position.product === "lend")
      .map((position) => {
        const market = marketBySlug.get(position.marketSlug)
        const suppliedUsd = toUsd(position.suppliedUsd6)
        const earnedUsd = toUsd(position.earnedUsd6)
        const priceUsd = market?.priceUsd && market.priceUsd > 0 ? market.priceUsd : 1
        const apyPct = Math.max(0, position.supplyApyPct ?? 0)
        return {
          id: String(position._id),
          walletProfileId: wallet,
          symbol: market?.symbol ?? position.marketSlug.toUpperCase(),
          name: market?.name ?? position.marketSlug,
          balance: suppliedUsd / priceUsd,
          priceUsd,
          suppliedUsd,
          earnedUsd,
          dailyEarnedUsd: (suppliedUsd * apyPct) / 100 / 365,
          apyPct,
        }
      })

    const collaterals: PortfolioCollateralRecord[] = state.positions
      .filter((position) => position.product === "borrow")
      .flatMap((position) => {
        const positionBorrowedUsd = position.debt.reduce(
          (sum, debt) => sum + calculateLiveBorrowDebt(debt).borrowedUsd,
          0,
        )
        const totalCollateralUsd = position.collateral.reduce(
          (sum, collateral) => sum + toUsd(collateral.collateralValueUsd6),
          0,
        )
        return position.collateral.map((collateral) => {
          const pool = poolBySlug.get(collateral.marketSlug)
          const collateralUsd = toUsd(collateral.collateralValueUsd6)
          const borrowedUsd = allocateDebtByCollateral(positionBorrowedUsd, collateralUsd, totalCollateralUsd)
          const maxLtv = pool?.maxLtvPct ?? 0
          // Liquidation threshold = explicit LT, else maxLtv + 10pp (capped 95%) — the same
          // basis as the credit engine and Convex persist gate. Raw maxLtv/CF understates HF and
          // disagrees with the action preview. maxLtv 0 (unknown pool) stays 0, never fabricated.
          const thresholdPct =
            pool?.liquidationThresholdPct ?? (maxLtv > 0 ? liquidationThresholdPctFromMaxLtvPct(maxLtv) : 0)
          const liquidationUsd = collateralUsd * (thresholdPct / 100)
          const visuals = pool?.visuals?.slice(0, 2) ?? []
          const fallbackVisual = {
            symbol: "AVA",
            shortLabel: "A",
            bgClassName: "bg-brand",
            textClassName: "text-brand-foreground",
          }
          return {
            id: String(collateral._id),
            walletProfileId: wallet,
            pool: {
              id: collateral.marketSlug,
              name: pool?.name ?? collateral.marketSlug,
              venue: pool?.venue ?? "Avana",
              category: pool?.category ?? "sandbox",
              collateralUsd,
              maxLtv,
              borrowPowerUsd: collateralUsd * (Math.min(maxLtv, 100) / 100),
              liquidationUsd,
              pairApr: pool?.pairAprPct ?? 0,
              visuals: [visuals[0] ?? fallbackVisual, visuals[1] ?? fallbackVisual],
            },
            borrowedUsd,
            healthFactor: borrowedUsd > 0 ? liquidationUsd / borrowedUsd : null,
            pairApr: pool?.pairAprPct ?? 0,
            feesUsd: 0,
          }
        })
      })

    const debts: PortfolioDebtRecord[] = state.positions
      .filter((position) => position.product === "borrow")
      .flatMap((position) =>
        position.debt.map((debt) => {
          const accounting = calculateLiveBorrowDebt(debt)
          return {
            id: String(debt._id),
            walletProfileId: wallet,
            poolId: debt.marketSlug ?? position.marketSlug,
            debtAssetSymbol: debt.baseAssetId.toUpperCase(),
            ...accounting,
          }
        }),
      )

    const activity: PortfolioActivityRecord[] = state.transactions.map((transaction) => ({
      id: String(transaction._id),
      walletProfileId: wallet,
      at: new Date(transaction.at).toISOString(),
      product: transaction.product,
      kind:
        transaction.kind === "deposit"
          ? "supply"
          : transaction.kind === "multiply"
            ? "open"
            : transaction.kind === "deleverage"
              ? "reduce"
              : (transaction.kind as PortfolioActivityKind),
      status: transaction.status === "success" ? "confirmed" : transaction.status,
      amountUsd: transaction.amountUsd,
      primaryLabel: transaction.marketSlug ?? transaction.product,
      secondaryLabel: transaction.kind,
      txHash: transaction.syntheticTxHash,
    }))

    const data: PortfolioPageRecords = {
      walletProfile: { id: wallet, walletAddress: wallet },
      snapshots: state.snapshots.map((snapshot) => ({
        walletProfileId: wallet,
        timestamp: new Date(snapshot.at).toISOString(),
        totalValueUsd: snapshot.totalValueUsd,
        totalSuppliedUsd: snapshot.totalSuppliedUsd,
        totalBorrowedUsd: snapshot.totalBorrowedUsd,
        availableToBorrowUsd: snapshot.availableToBorrowUsd,
        totalMultiplyExposureUsd: snapshot.totalMultiplyExposureUsd,
        totalEarnedUsd: snapshot.totalEarnedUsd,
      })),
      supplies,
      debts,
      collaterals,
      multiplyCreditLines: {
        walletProfileId: wallet,
        approvedUsd: Math.max(0, totalMultiplyCollateral - totalMultiplyDebt),
        liquidationThresholdUsd: totalMultiplyCollateral * MULTIPLY_LIQUIDATION_THRESHOLD_FACTOR,
        // Worst active-position HF (not average), matching the client read-model so the
        // multiply hero does not change on hydration.
        averageHealthFactor: worstMultiplyHealthFactor(healthFactors, multiplyPositions.length),
        currentLtvPct: totalMultiplyCollateral > 0 ? (totalMultiplyDebt / totalMultiplyCollateral) * 100 : 0,
        totalBorrowedUsd: totalMultiplyDebt,
        totalCollateralUsd: totalMultiplyCollateral,
      },
      multiplyCollaterals: multiplyPositions.map((position) => {
        const market = marketBySlug.get(position.marketSlug)
        return {
          id: String(position._id),
          walletProfileId: wallet,
          label: market?.name ?? position.marketSlug,
          collateralToken: market?.symbol ?? position.marketSlug,
          borrowableToken: position.assetId ?? "USD",
          multiplier: position.multiplier ?? 1,
          protocol: market?.venueLabel ?? "Avana",
          healthFactor: typeof position.healthFactor === "number" ? position.healthFactor : Number.POSITIVE_INFINITY,
          collateralUsd: position.collateralValueUsd ?? 0,
          borrowPowerUsd: Math.max(0, (position.collateralValueUsd ?? 0) - (position.debtValueUsd ?? 0)),
        }
      }),
      multiplyPositions: multiplyPositions.map((position) => {
        const collateralUsd = position.collateralValueUsd ?? 0
        const accounting = calculateLiveMultiplyPosition({
          collateralUsd,
          debtUsd: position.debtValueUsd ?? 0,
          netApyPct: position.netApyPct ?? 0,
          openedAt: position.openedAt,
          now: Date.now(),
        })
        return {
          id: String(position._id),
          walletProfileId: wallet,
          symbol: marketBySlug.get(position.marketSlug)?.symbol ?? position.marketSlug,
          label: marketBySlug.get(position.marketSlug)?.name ?? position.marketSlug,
          side: "long",
          leverage: position.multiplier ?? 1,
          collateralUsd,
          exposureUsd: accounting.exposureUsd,
          pnlUsd: accounting.pnlUsd,
          pnlPct: accounting.pnlPct,
          status: position.status,
        }
      }),
      openOrders: [],
      twapOrders: [],
      activity,
      strategies: [],
      rewards: {
        walletProfileId: wallet,
        claimableUsd: 0,
        earnedUsd: claimedRewards.reduce((sum, claim) => sum + claim.amount, 0),
        settledUsd: claimedRewards.reduce((sum, claim) => sum + claim.amount, 0),
        pendingUsd: 0,
      },
    }

    return {
      fetchedAt: new Date().toISOString(),
      pageInfo: { nextCursor: null, hasMore: false },
      data,
    }
  },
}
