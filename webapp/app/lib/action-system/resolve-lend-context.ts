import type { LendSystemState } from "@/app/lib/lend-system/model"
import { formatActionAmount, formatActionApproxUsd, formatActionRatioPercent } from "@/app/lib/action-system/formatters"
import { formatLendMarketDropdownSublabel } from "@/app/lib/lend-system/market-labels"
import { getWalletBalanceForLendMarket } from "@/app/lib/lend-system/wallet-balances"
import { canonicalPriceUsd } from "@/app/lib/prices/canonical"

type LendContextSession = {
  state: LendSystemState
}

/**
 * The live oracle price (hydrated on the server, so it is right on first paint) before the
 * market's own price, which starts at the catalog figure until market data merges: the picker
 * flashed "$12,500" (the catalog value) before "$17,360" for the same ETH.
 */
function livePriceUsd(market: LendSystemState["markets"][string]) {
  return canonicalPriceUsd(market.asset.symbol) ?? market.assetPriceUsd
}

export function lendDepositSelectItems(session: LendContextSession, walletId: string) {
  return Object.values(session.state.markets)
    .map((market) => {
      const walletBalance = getWalletBalanceForLendMarket(session.state, walletId, market)
      const balanceUsd = walletBalance * livePriceUsd(market)
      return {
        id: market.marketId,
        name: market.asset.name,
        symbol: market.asset.symbol,
        sublabel: formatLendMarketDropdownSublabel(market.asset.symbol),
        trailingLabel: formatActionApproxUsd(balanceUsd),
        trailingSublabel: `${formatActionRatioPercent(market.supplyApy)} APY`,
        walletBalance,
      }
    })
    .filter((item) => item.walletBalance > 0)
    .map(({ walletBalance: _walletBalance, ...item }) => item)
}

export function lendWithdrawSelectItems(session: LendContextSession, walletId: string) {
  return Object.values(session.state.positions)
    .filter((position) => position.walletId === walletId && position.status === "active")
    .map((position) => {
      const market = session.state.markets[position.marketId]
      const suppliedUsd = position.currentSuppliedAmount * (market ? livePriceUsd(market) : 0)
      return {
        id: position.marketId,
        name: market?.asset.name ?? position.marketId,
        symbol: market?.asset.symbol ?? "Asset",
        sublabel: market ? formatLendMarketDropdownSublabel(market.asset.symbol) : undefined,
        trailingLabel: formatActionApproxUsd(suppliedUsd),
        trailingSublabel: `${formatActionAmount(position.currentSuppliedAmount, market?.asset.symbol ?? "", 4).trim()} supplied`,
      }
    })
}
