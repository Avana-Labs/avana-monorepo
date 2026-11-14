import { SWAP_CHAIN_ID, getSwapAsset } from "./catalog"
import { getSwapEligibility } from "./eligibility"
import { formatTokenDisplaySymbol } from "@/app/lib/token-icons"
import { BORROW_POOL_CATALOG } from "@/app/lib/borrow-sim"
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

export const DEMO_SWAP_BALANCES: UserAssetBalance[] = [
  {
    id: "wallet-eth",
    walletId: "demo-wallet",
    assetId: "eth",
    amount: 0.012,
    sourceType: "wallet",
  },
  {
    id: "wallet-usdc",
    walletId: "demo-wallet",
    assetId: "usdc",
    amount: 840,
    sourceType: "wallet",
  },
  {
    id: "wallet-link",
    walletId: "demo-wallet",
    assetId: "link",
    amount: 24,
    sourceType: "wallet",
  },
  {
    id: "wallet-eth-usdc-lp",
    walletId: "demo-wallet",
    assetId: "eth-usdc-lp",
    amount: 6.4,
    ltvPct: 76.5,
    sourceType: "wallet",
  },
  {
    id: "lend-deposited-gho",
    walletId: "demo-wallet",
    assetId: "gho",
    amount: 1250,
    sourceType: "lend_deposited",
    sourcePositionId: "lend-gho",
  },
  {
    id: "multiply-active-eth",
    walletId: "demo-wallet",
    assetId: "eth",
    amount: 3,
    sourceType: "multiply_active",
    sourcePositionId: "multiply-eth-usdc",
  },
]

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
    case "multiply_available":
      return "Multiply available"
    case "multiply_active":
      return "Active loop"
    case "multiply_debt":
      return "Loop debt"
    case "protocol_locked":
      return "Protocol locked"
  }
}

export function getUserSwapBalances(walletId: string, balances: UserAssetBalance[] = DEMO_SWAP_BALANCES) {
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
  balances = DEMO_SWAP_BALANCES,
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
      // Multiply available buckets are USD ledgers. Their token amount may be a
      // legacy USD-denominated value, so never revalue them as `amount × price`.
      // Derive the display quantity from the canonical stored USD value instead.
      const isMultiplyAvailable = balance.sourceType === "multiply_available"
      const hasLivePrice = livePrice != null && Number.isFinite(livePrice) && livePrice > 0
      const valueUsd = isMultiplyAvailable ? storedValueUsd : hasLivePrice ? balance.amount * livePrice : storedValueUsd
      const amount = isMultiplyAvailable && hasLivePrice ? valueUsd / livePrice : balance.amount
      const catalogPool = balance.sourcePositionId
        ? BORROW_POOL_CATALOG.find((pool) => pool.id === balance.sourcePositionId)
        : undefined
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
        ltvPct: balance.ltvPct ?? catalogPool?.ltv,
        swappable: eligibility.eligible,
        restrictionReason: eligibility.eligible ? null : eligibility.reason,
        sourcePositionId: balance.sourcePositionId,
      }
    })
    .sort((left, right) => right.valueUsd - left.valueUsd)
}
