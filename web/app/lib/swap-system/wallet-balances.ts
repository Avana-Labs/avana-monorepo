import { SWAP_CHAIN_ID, getSwapAsset } from "./catalog"
import { getSwapEligibility } from "./eligibility"
import { formatTokenDisplaySymbol } from "@/app/lib/token-icons"
import { extraTokenName } from "@/app/lib/markets/extra-token-names"
import type { SwapContext, SwapRestrictionReason, UserAssetBalance } from "./contracts"

export type DashboardWalletBalanceRow = {
  id: string
  assetId: string
  symbol: string
  name: string
  amount: number
  valueUsd: number
  sourceType: UserAssetBalance["sourceType"]
  sourceLabel: string
  isLpToken: boolean
  isWalletHeld: boolean
  swappable: boolean
  restrictionReason: SwapRestrictionReason | null
  sourcePositionId?: string
  unitPriceUsd?: number
  ltvPct?: number
}

function sourceLabel(sourceType: UserAssetBalance["sourceType"]) {
  switch (sourceType) {
    case "wallet":
      return "Wallet"
    case "lend_available":
      return "Lend available"
    case "lend_deposited":
      return "Lend deposited"
    case "borrow_collateral_unpledged":
      return "Borrow collateral"
    case "borrow_collateral_pledged":
      return "Pledged collateral"
    case "borrow_debt":
      return "Borrow debt"
    case "borrow_claimable":
      return "Pool fees"
    case "protocol_locked":
      return "Protocol locked"
  }
}

export function getUserSwapBalances(walletId: string, balances: UserAssetBalance[] = []) {
  return balances.filter((balance) => balance.walletId === walletId)
}

/**
 * Rows currently available to the wallet owner. Returned product balances are included, while
 * deposited, pledged, and active positions remain on their product tab. A canonical liquid token
 * row wins over an available product mirror so the dashboard cannot double-count it.
 */
export function selectDashboardWalletValueRows(rows: DashboardWalletBalanceRow[]): DashboardWalletBalanceRow[] {
  const candidates = rows.filter(
    (row) =>
      row.sourceType === "wallet" ||
      row.sourceType === "lend_available" ||
      row.sourceType === "borrow_collateral_unpledged",
  )
  const liquidAssetIds = new Set(candidates.filter((row) => row.sourceType === "wallet").map((row) => row.assetId))
  return candidates.filter((row) => row.sourceType === "wallet" || !liquidAssetIds.has(row.assetId))
}

export function buildDashboardWalletBalanceRows({
  walletId,
  balances = [],
  context = { originProduct: "wallet", chainId: SWAP_CHAIN_ID },
  priceFor,
}: {
  walletId: string
  balances?: UserAssetBalance[]
  context?: SwapContext
  /**
   * Live reactive token price lookup (symbol → USD), e.g. `useCanonicalPriceFor()`.
   * When provided, NON-LP rows are valued at `amount × priceFor(symbol)` so the wallet
   * reflects the current oracle instead of the frozen `valueUsd` stored at tx time. LP
   * rows keep their stored value (the canonical LP basis shown on the detail pages);
   * an unpriced symbol falls back to the stored value / static catalog price.
   */
  priceFor?: (symbol: string) => number | undefined
}): DashboardWalletBalanceRow[] {
  const merged = new Map<string, UserAssetBalance>()
  for (const balance of getUserSwapBalances(walletId, balances)) {
    const valueUsd = balance.valueUsd ?? balance.amount * (getSwapAsset(balance.assetId)?.priceUsd ?? 0)
    if (balance.amount <= 0 && valueUsd <= 0) continue
    const asset = getSwapAsset(balance.assetId)
    const isLpToken = balance.isLpToken ?? asset?.isLpToken ?? false
    const key = isLpToken ? `${balance.assetId}:${balance.sourceType}` : balance.id
    const existing = merged.get(key)
    if (!existing) {
      merged.set(key, { ...balance, valueUsd })
      continue
    }
    merged.set(key, {
      ...existing,
      amount: existing.amount + balance.amount,
      valueUsd: (existing.valueUsd ?? existing.amount * (getSwapAsset(existing.assetId)?.priceUsd ?? 0)) + valueUsd,
    })
  }

  return [...merged.values()]
    .map((balance) => {
      const asset = getSwapAsset(balance.assetId)
      const eligibility = getSwapEligibility(balance, context)
      const storedValueUsd = balance.valueUsd ?? balance.amount * (asset?.priceUsd ?? 0)
      // Reprice NON-LP tokens off the live oracle when available so the wallet is reactive
      // and never pinned to a frozen stored value. LP rows keep the canonical stored basis.
      const isLpToken = balance.isLpToken ?? asset?.isLpToken ?? false
      const livePrice = !isLpToken ? priceFor?.(asset?.symbol ?? balance.assetId) : undefined
      const hasLivePrice = livePrice != null && Number.isFinite(livePrice) && livePrice > 0
      const valueUsd = hasLivePrice ? balance.amount * livePrice : storedValueUsd
      const amount = balance.amount
      const symbol = asset?.symbol ?? balance.symbol ?? formatTokenDisplaySymbol(balance.assetId)
      // Tokens outside the swap catalog (e.g. OP from rewards) are stored with name = ticker;
      // prefer the catalog-wide token name ("Optimism") over repeating the ticker.
      const storedName = balance.name && balance.name.toUpperCase() !== symbol.toUpperCase() ? balance.name : undefined
      return {
        id: balance.id,
        assetId: balance.assetId,
        symbol,
        name: asset?.name ?? storedName ?? extraTokenName(symbol) ?? balance.name ?? symbol,
        amount,
        valueUsd,
        sourceType: balance.sourceType,
        sourceLabel: sourceLabel(balance.sourceType),
        isLpToken,
        isWalletHeld: balance.sourceType === "wallet",
        unitPriceUsd: balance.unitPriceUsd,
        ltvPct: balance.ltvPct,
        swappable: eligibility.eligible,
        restrictionReason: eligibility.eligible ? null : eligibility.reason,
        sourcePositionId: balance.sourcePositionId,
      }
    })
    .sort((left, right) => right.valueUsd - left.valueUsd)
}
