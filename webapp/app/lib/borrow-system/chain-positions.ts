import {
  RAY,
  TOKEN_SCALE,
  type BorrowMarketRecord,
  type UserCollateralPosition,
  type UserDebtPosition,
  type UserRewardPosition,
} from "@/app/lib/borrow-system/model"

/** One account row of services/convex `wallet.positions.borrowAccounts`. */
export type ChainBorrowAccountRef = {
  chainId: number
  marketId: string
  spoke: string
  proxy: string
  /** The Borrow list's pool slug of the account's market (the engine's market id), null before the market is listed. */
  poolSlug: string | null
}

/** One debt reserve row of `wallet.positions.borrowAccounts`. */
export type ChainDebtReserveRef = {
  chainId: number
  spoke: string
  reserveId: string
  asset: string
  assetSlug: string
  decimals: number
  /** USD, 8 decimals, per whole token; null when no Hub asset prices it. */
  priceUsd8: string | null
}

/** The Lens `AccountView` fields read here, as viem decodes them. */
export type AccountViewLike = {
  marketId: bigint
  spoke: string
  proxy: string
  deployed: boolean
  totalCollateralValue: bigint
  totalDebtValueRay: bigint
  debts: readonly { reserveId: bigint; asset: string; total: bigint }[]
  markets: readonly { collateralEnabled: boolean; suppliedAssets: bigint }[]
}

export type ChainBorrowPositions = {
  collateralPositions: UserCollateralPosition[]
  debtPositions: UserDebtPosition[]
  /** The accounts' uncollected LP fees (chainRewardPositions); left as they are when absent. */
  rewardPositions?: UserRewardPosition[]
}

/** Aave values are USD × 1e26 (`IAaveOracle` units × 1e18); debt values also × RAY. */
const VALUE_TO_USD6 = 10n ** 20n

const lower = (value: string) => value.toLowerCase()

/**
 * The engine's collateral and debt positions of a wallet, from the Lens accounts of its markets. Values are the chain's:
 * each collateral position is sized so the engine values it at the account's collateral value at the market's LP price,
 * and each debt at its reserve's total owed at the Hub price, so health, credit and rates read the chain's numbers.
 * Accounts of markets the Borrow list does not show are left out.
 */
export function chainBorrowPositions(
  views: readonly { chainId: number; view: AccountViewLike }[],
  accounts: readonly ChainBorrowAccountRef[],
  reserves: readonly ChainDebtReserveRef[],
  markets: Readonly<Record<string, BorrowMarketRecord>>,
): ChainBorrowPositions {
  const collateralPositions: UserCollateralPosition[] = []
  const debtPositions: UserDebtPosition[] = []

  for (const { chainId, view } of views) {
    const ref = accounts.find(
      (a) => a.chainId === chainId && a.marketId === view.marketId.toString() && lower(a.proxy) === lower(view.proxy),
    )
    const poolSlug = ref?.poolSlug
    const market = poolSlug ? markets[poolSlug] : undefined
    if (!ref || !poolSlug || !market) continue
    const key = `${chainId}:${view.marketId.toString()}`

    const collateralUsd6 = view.totalCollateralValue / VALUE_TO_USD6
    const lpPriceUsd6 = market.snapshot.lpTokenPriceUsd6
    if (collateralUsd6 > 0n && lpPriceUsd6 > 0n) {
      const units = (collateralUsd6 * TOKEN_SCALE) / lpPriceUsd6
      collateralPositions.push({
        id: `collateral:${key}`,
        marketId: poolSlug,
        collateralShares: units,
        principalTokenAmount: units,
        collateralEnabled: view.markets[0]?.collateralEnabled ?? true,
      })
    }

    const owed = view.debts.filter((d) => d.total > 0n)
    const totalDebtUsd6 = view.totalDebtValueRay / (VALUE_TO_USD6 * RAY)
    for (const debt of owed) {
      const reserve = reserves.find(
        (r) => r.chainId === chainId && lower(r.spoke) === lower(view.spoke) && r.reserveId === debt.reserveId.toString(),
      )
      if (!reserve) continue
      const priceUsd6 = reserve.priceUsd8 ? BigInt(reserve.priceUsd8) / 100n : 0n
      // A lone debt is the account's whole debt value; several are each valued at their Hub price.
      const usd6 =
        owed.length === 1 ? totalDebtUsd6 : (debt.total * priceUsd6) / 10n ** BigInt(reserve.decimals)
      if (usd6 <= 0n) continue
      debtPositions.push({
        id: `debt:${key}:${debt.reserveId.toString()}`,
        assetId: reserve.assetSlug,
        baseAssetId: reserve.assetSlug,
        spokeId: market.spokeId,
        marketId: poolSlug,
        debtSharesUsd6: usd6,
        debtIndexRay: RAY,
        // The rate shown is the market's (base × (1 + collateral risk)); the engine's own rate is not used.
        borrowRateWad: 0n,
        principalBorrowedUsd6: usd6,
        ...(priceUsd6 > 0n ? { priceAtBorrowUsd6: priceUsd6 } : {}),
      })
    }
  }

  return { collateralPositions, debtPositions }
}
