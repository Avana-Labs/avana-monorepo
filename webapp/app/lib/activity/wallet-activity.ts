import type { PortfolioActivityRow } from "@/app/lib/data/providers/portfolio/types"
import { formatBorrowLpSymbolLabel } from "@/app/lib/borrow-system/market-labels"
import { formatActivityTokenAmount } from "@/app/lib/currency/format"

/**
 * The wallet's indexed activity (services/convex `wallet.activity.listForWallet`, the last 30 days, then the older
 * rows of `wallet.history.older`, which carry a token amount and no USD value) as the dashboard feed's rows, with the same products, kinds, signs and labels the session's own rows use
 * (`mapTransactionHistoryToActivityRows`, `buildLendActivityHistory`):
 * - Borrow rows come from the pool page's events (the AaveAdapter's), which name the market. The same borrow or repay
 *   also lands on the asset page from the CDP Spoke; that copy is left out.
 * - Lend rows are the Lend page's supplies and withdrawals.
 *
 * Swaps are not indexed, so they come only from the swap session's receipts.
 * TODO(activity): index a wallet's swaps from the front-end fee transfer every Avana swap pays to `feeRecipient`.
 */

/**
 * One row of `wallet.activity.listForWallet` or `wallet.history.older` (services/convex `WalletActivityRow`), the
 * fields read here.
 */
export type WalletActivityRowLike = {
  id: string
  at: string
  kind: string
  amountUsd?: number
  tokenAmountLabel?: string
  tokenSymbol?: string
  txHash?: string
  chainId: number
  page?: { scope: "lend" | "asset" | "pool"; slug: string }
}

type MarketDisplayLookup = Record<string, { display?: { visuals?: Array<{ symbol: string }>; name?: string } }>

const BORROW_KINDS: Record<string, PortfolioActivityRow["kind"]> = {
  supply: "pledge",
  withdraw: "withdraw",
  reduce: "withdraw",
  borrow: "borrow",
  repay: "repay",
  liquidation: "liquidation",
}

const LEND_KINDS: Record<string, PortfolioActivityRow["kind"]> = { supply: "supply", withdraw: "withdraw" }

/** "1,234.5 USDC" → 1234.5. */
function tokenAmount(label: string | undefined): number {
  const value = Number((label ?? "").split(" ")[0]?.replace(/,/g, ""))
  return Number.isFinite(value) ? value : 0
}

/**
 * A row older than the indexed window (`wallet.history.older`) has no USD value; its amount cell shows the token
 * amount instead.
 */
function withoutUsd(row: WalletActivityRowLike): Pick<PortfolioActivityRow, "tokenAmountLabel"> | null {
  if (row.amountUsd !== undefined) return null
  const symbol = row.tokenSymbol ?? row.tokenAmountLabel?.split(" ").slice(1).join(" ")
  return row.tokenAmountLabel && symbol
    ? { tokenAmountLabel: formatActivityTokenAmount(tokenAmount(row.tokenAmountLabel), symbol) }
    : {}
}

function borrowRow(
  row: WalletActivityRowLike,
  slug: string,
  markets: MarketDisplayLookup,
): PortfolioActivityRow | null {
  const kind = BORROW_KINDS[row.kind]
  if (!kind) return null
  const older = withoutUsd(row)
  const amountUsd = Math.abs(row.amountUsd ?? 0)
  const signed = kind === "borrow" || kind === "withdraw" || kind === "liquidation" ? -amountUsd : amountUsd
  // Debt actions label by the borrowed asset, collateral actions by the pool, with the pool as context on debt rows.
  const isDebtAction = kind === "borrow" || kind === "repay"
  const market = markets[slug]
  const poolLabel = market ? formatBorrowLpSymbolLabel(market) : undefined
  const fallbackLabel =
    kind === "pledge" ? "Pledge" : kind === "liquidation" ? "Liquidation" : kind[0]!.toUpperCase() + kind.slice(1)
  return {
    id: row.id,
    at: row.at,
    product: "borrow",
    kind,
    status: "confirmed",
    ...(older ?? { amountUsd: signed }),
    primaryLabel: isDebtAction ? (row.tokenSymbol ?? fallbackLabel) : (poolLabel ?? fallbackLabel),
    secondaryLabel: isDebtAction && poolLabel ? `via ${poolLabel}` : "",
    marketId: isDebtAction ? row.tokenSymbol?.toLowerCase() : slug,
    txHash: row.txHash ?? "",
  }
}

function lendRow(row: WalletActivityRowLike, slug: string): PortfolioActivityRow | null {
  const kind = LEND_KINDS[row.kind]
  if (!kind) return null
  const symbol = row.tokenSymbol ?? slug.toUpperCase()
  return {
    id: row.id,
    at: row.at,
    product: "lend",
    kind,
    status: "confirmed",
    ...(withoutUsd(row) ?? { amountUsd: row.amountUsd ?? 0 }),
    primaryLabel: symbol,
    secondaryLabel: formatActivityTokenAmount(tokenAmount(row.tokenAmountLabel), symbol),
    txHash: row.txHash ?? "",
    marketId: slug,
  }
}

/** Feed rows of indexed activity; events no feed row shows (asset-page copies, Lend-page borrows) are left out. */
export function mapWalletActivityRows(
  rows: readonly WalletActivityRowLike[],
  borrowMarkets: MarketDisplayLookup = {},
): PortfolioActivityRow[] {
  const out: PortfolioActivityRow[] = []
  for (const row of rows) {
    if (!row.page) continue
    const mapped =
      row.page.scope === "pool"
        ? borrowRow(row, row.page.slug, borrowMarkets)
        : row.page.scope === "lend"
          ? lendRow(row, row.page.slug)
          : null
    if (mapped) out.push(mapped)
  }
  return out
}
