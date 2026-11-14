import { LANGUAGE_HTML_LANG } from "@/app/lib/i18n/language-html-lang"
import type { LanguageCode } from "@/app/components/display-preferences"
import { formatCompactUsd } from "@/app/lib/format"
import {
  formatDetailTokenAmount,
  isUsdMirroredTokenLabel,
  parseCompactUsdLabel,
  seedPriceUsdForSymbol,
  tokenAmountFromUsd,
} from "@/app/lib/detail-page/transaction-display"
import type { TxHistoryRow } from "@/app/lib/borrow-detail"
import type { MultiplyTxHistoryRow } from "@/app/lib/multiply-detail"
import type { LendTransactionHistoryItem } from "@/app/lib/lend-system/contracts"
import type { TransactionHistoryItem } from "@/app/lib/borrow-system/contracts"
import type { MultiplyTransactionHistoryItem } from "@/app/lib/multiply-system/contracts"

/** Shared row shape for detail-page transaction tables. */
export type DetailTransactionRow = {
  id: string
  at: string
  timeLabel?: string
  kind: string
  amountLabel: string
  /** Historical USD at transaction time — used only to bootstrap frozen token qty. */
  amountUsd?: number
  tokenAmountLabel?: string
  token0AmountLabel?: string
  token1AmountLabel?: string
  tokenSymbol?: string
  tokenSymbolSecondary?: string
  counterpartyLabel?: string
  walletLabel?: string
  walletHref?: string
  txHashShort: string
}

export function formatWalletLabel(walletAddress?: string): string | undefined {
  const normalized = walletAddress?.trim()
  if (!normalized) return undefined
  if (normalized.length <= 12) return normalized
  return `${normalized.slice(0, 6)}…${normalized.slice(-4)}`
}

export function normalizeDetailMarketKey(value: string): string {
  return value.trim().toLowerCase().replaceAll("_", "-")
}

function detailMarketKeysMatch(left: string | undefined, right: string | undefined): boolean {
  if (!left || !right) return false
  return normalizeDetailMarketKey(left) === normalizeDetailMarketKey(right)
}

/** `gho` and `bal-stable:gho` are the same asset; `uni-v2:gho` is not. */
export function scopedAssetKeysMatch(left: string | undefined, right: string | undefined): boolean {
  if (!left || !right) return false
  const a = normalizeDetailMarketKey(left)
  const b = normalizeDetailMarketKey(right)
  if (a === b) return true
  if (a.includes(":") === b.includes(":")) return false
  return a.slice(a.lastIndexOf(":") + 1) === b.slice(b.lastIndexOf(":") + 1)
}

export function mapMultiplyHistoryKind(kind: string): string {
  if (kind === "multiply" || kind === "open") return "open"
  if (kind === "close" || kind === "liquidation") return "close"
  if (kind === "deleverage" || kind === "reduce" || kind === "repay" || kind === "withdraw") return "reduce"
  if (kind === "borrow" || kind === "supply" || kind === "deposit" || kind === "add") return "add"
  if (kind === "claim" || kind === "rewards" || kind === "interest") return "interest"
  return "rebalance"
}

export function formatRelativeTime(iso: string, language: LanguageCode = "EN") {
  const locale = LANGUAGE_HTML_LANG[language] ?? "en"
  const elapsedMs = Math.max(0, Date.now() - new Date(iso).getTime())
  const totalSeconds = Math.max(1, Math.floor(elapsedMs / 1000))
  const rtf = new Intl.RelativeTimeFormat(locale, { numeric: "always", style: "narrow" })

  if (totalSeconds < 60) return rtf.format(-totalSeconds, "second")
  const totalMinutes = Math.floor(totalSeconds / 60)
  if (totalMinutes < 60) return rtf.format(-totalMinutes, "minute")
  const totalHours = Math.floor(totalMinutes / 60)
  if (totalHours < 24) return rtf.format(-totalHours, "hour")
  return rtf.format(-Math.floor(totalHours / 24), "day")
}

function formatRelativeAge(elapsedMs: number) {
  const s = Math.max(1, Math.floor(elapsedMs / 1000))
  if (s < 60) return `${s}s`
  const m = Math.floor(s / 60)
  if (m < 60) return `${m}m`
  const h = Math.floor(m / 60)
  if (h < 24) return `${h}h`
  return `${Math.floor(h / 24)}d`
}

export function mergeTransactionRows(
  sessionRows: DetailTransactionRow[],
  convexRows: DetailTransactionRow[],
  seedRows: DetailTransactionRow[] = [],
  limit = 25,
): DetailTransactionRow[] {
  const seen = new Set<string>()
  const merged: DetailTransactionRow[] = []
  for (const row of [...sessionRows, ...convexRows, ...seedRows]) {
    if (seen.has(row.id)) continue
    seen.add(row.id)
    merged.push(row)
    if (merged.length >= limit) break
  }
  return merged
}

export function mapBorrowTxRow(row: TxHistoryRow): DetailTransactionRow {
  const pairedAmount =
    row.token0AmountLabel && row.token1AmountLabel ? `${row.token0AmountLabel} / ${row.token1AmountLabel}` : undefined
  return {
    id: row.id,
    at: row.at,
    timeLabel: row.timeLabel,
    kind: row.kind,
    amountLabel: row.amountLabel,
    amountUsd: parseCompactUsdLabel(row.amountLabel.replace(/^\+/, "")) ?? undefined,
    tokenAmountLabel: row.tokenAmountLabel ?? pairedAmount ?? row.token0AmountLabel ?? row.token1AmountLabel,
    token0AmountLabel: row.token0AmountLabel,
    token1AmountLabel: row.token1AmountLabel,
    tokenSymbol: row.tokenSymbol,
    tokenSymbolSecondary: row.tokenSymbolSecondary,
    counterpartyLabel: row.counterpartyLabel,
    walletLabel: row.walletLabel,
    walletHref: row.walletHref,
    txHashShort: row.txHashShort,
  }
}

export function mapMultiplyTxRow(row: MultiplyTxHistoryRow): DetailTransactionRow {
  return {
    id: row.id,
    at: row.at,
    timeLabel: row.timeLabel,
    kind: row.kind,
    amountLabel: row.amountLabel,
    tokenAmountLabel: row.tokenAmountLabel ?? inferTokenAmountFromLabel(row.amountLabel),
    tokenSymbol: row.tokenSymbol ?? inferSymbolFromCounterparty(row.counterpartyLabel),
    tokenSymbolSecondary: row.tokenSymbolSecondary,
    counterpartyLabel: row.counterpartyLabel,
    walletLabel: row.walletLabel,
    walletHref: row.walletHref,
    txHashShort: row.txHashShort,
  }
}

export function mapLendSessionRows(
  history: LendTransactionHistoryItem[],
  marketId: string,
  assetSymbol: string,
  priceUsd?: number,
  walletAddress?: string,
): DetailTransactionRow[] {
  const now = Date.now()
  return history
    .filter((item) => detailMarketKeysMatch(item.marketId, marketId))
    .map((item) => {
      const signedUsd =
        priceUsd != null && priceUsd > 0
          ? formatCompactUsd(item.amount * priceUsd * (item.kind === "withdraw" ? -1 : 1))
          : undefined
      return {
        id: item.id,
        at: new Date(item.timestamp).toISOString(),
        timeLabel: formatRelativeAge(now - item.timestamp),
        kind: item.kind === "deposit" ? "supply" : item.kind === "claim" ? "rewards" : "withdraw",
        amountLabel: signedUsd ?? "—",
        amountUsd: priceUsd != null && priceUsd > 0 ? item.amount * priceUsd : undefined,
        tokenAmountLabel: formatDetailTokenAmount(item.amount),
        tokenSymbol: assetSymbol,
        walletLabel: formatWalletLabel(walletAddress),
        txHashShort: item.hash.slice(0, 10),
      }
    })
}

/**
 * Borrow splits across two pages: `scope: "pool"` shows the COLLATERAL side (pledge, remove,
 * claim fees, liquidation) and `scope: "asset"` the DEBT side (borrow, repay). Omit `scope`
 * for no side filter.
 */
export function mapBorrowSessionRows(
  history: TransactionHistoryItem[],
  marketSlug?: string,
  assetSymbol?: string,
  scope?: "pool" | "asset",
  walletAddress?: string,
): DetailTransactionRow[] {
  const now = Date.now()
  const actionToKind: Record<TransactionHistoryItem["kind"], string> = {
    deposit: "supply",
    borrow: "borrow",
    repay: "repay",
    withdraw: "withdraw",
    liquidate: "liquidation",
    claim: "rewards",
  }
  const allowsSide = (kind: TransactionHistoryItem["kind"]) => {
    if (scope !== "pool" && scope !== "asset") return true
    const debtSide = kind === "borrow" || kind === "repay"
    return scope === "asset" ? debtSide : !debtSide
  }
  return history
    .filter(
      (item) =>
        allowsSide(item.kind) &&
        (!marketSlug ||
          scopedAssetKeysMatch(item.marketId, marketSlug) ||
          scopedAssetKeysMatch(item.assetId, marketSlug)),
    )
    .map((item) => {
      const kind = actionToKind[item.kind]
      const usd = Number(item.executedAmountUsd6) / 1_000_000
      const symbol = assetSymbol ?? item.assetId?.split(":").pop()?.toUpperCase() ?? "USD"
      const seedPrice = seedPriceUsdForSymbol(symbol)
      const tokenQty = usd / seedPrice
      return {
        id: item.id,
        at: new Date(item.timestamp).toISOString(),
        timeLabel: formatRelativeAge(now - item.timestamp),
        kind,
        amountLabel: formatCompactUsd(usd),
        amountUsd: usd,
        tokenAmountLabel: formatDetailTokenAmount(tokenQty),
        tokenSymbol: symbol,
        walletLabel: formatWalletLabel(walletAddress),
        txHashShort: item.hash.slice(0, 10),
      }
    })
}

export function mapMultiplySessionRows(
  history: MultiplyTransactionHistoryItem[],
  marketId: string,
  collateralSymbol: string,
  borrowableSymbol: string,
  walletAddress?: string,
): DetailTransactionRow[] {
  const now = Date.now()
  return history
    .filter((item) => detailMarketKeysMatch(item.marketId, marketId))
    .map((item) => {
      const usd = item.amountUsd
      const tokenQty = usd / seedPriceUsdForSymbol(collateralSymbol)
      return {
        id: item.id,
        at: new Date(item.timestamp).toISOString(),
        timeLabel: formatRelativeAge(now - item.timestamp),
        kind: mapMultiplyHistoryKind(item.kind),
        amountLabel: formatCompactUsd(usd),
        amountUsd: usd,
        tokenAmountLabel: formatDetailTokenAmount(tokenQty),
        tokenSymbol: collateralSymbol,
        tokenSymbolSecondary: borrowableSymbol,
        counterpartyLabel: `${collateralSymbol}/${borrowableSymbol}`,
        walletLabel: formatWalletLabel(walletAddress),
        txHashShort: item.hash.slice(0, 10),
      }
    })
}

function inferTokenAmountFromLabel(label: string): string | undefined {
  if (label.includes("→")) return label.split("→").pop()?.trim()
  const numeric = label.replace(/[^0-9.KMx]/gi, "").trim()
  return numeric || undefined
}

function inferSymbolFromCounterparty(label?: string): string | undefined {
  if (!label) return undefined
  const token = label.split(/[\s/]/)[0]
  return token && /^[A-Za-z0-9.+-]+$/.test(token) ? token : undefined
}

export function enrichDetailTransactionRow(
  row: DetailTransactionRow,
  context: Record<string, string> = {},
  preset: "standard" | "pool" = "standard",
): DetailTransactionRow {
  if (preset === "pool" && context.token0Symbol && context.token1Symbol) {
    const w0 = context.token0Weight ? Number(context.token0Weight) : 0.5
    const w1 = context.token1Weight ? Number(context.token1Weight) : 0.5
    return enrichPoolRowWithPair(
      row,
      context.token0Symbol,
      context.token1Symbol,
      row.token0AmountLabel,
      row.token1AmountLabel,
      w0,
      w1,
    )
  }

  const symbol = row.tokenSymbol ?? context.assetSymbol ?? context.collateralSymbol
  if (!symbol) return row
  return enrichBorrowRowWithAsset(row, symbol)
}

export function enrichBorrowRowWithAsset(row: DetailTransactionRow, assetSymbol: string): DetailTransactionRow {
  const symbol = row.tokenSymbol ?? assetSymbol
  let tokenAmountLabel = row.tokenAmountLabel

  const usd = row.amountUsd ?? parseCompactUsdLabel(row.amountLabel)
  const hasValidToken =
    Boolean(tokenAmountLabel) && !isUsdMirroredTokenLabel({ ...row, tokenSymbol: symbol, tokenAmountLabel })

  if (!hasValidToken && usd != null) {
    tokenAmountLabel = tokenAmountFromUsd(usd, symbol)
  }

  return {
    ...row,
    tokenSymbol: symbol,
    tokenAmountLabel,
    amountUsd: usd ?? undefined,
  }
}

export function enrichPoolRowWithPair(
  row: DetailTransactionRow,
  token0Symbol: string,
  token1Symbol: string,
  token0AmountLabel?: string,
  token1AmountLabel?: string,
  token0Weight = 0.5,
  token1Weight = 0.5,
): DetailTransactionRow {
  const token0 = token0AmountLabel ?? row.token0AmountLabel
  const token1 = token1AmountLabel ?? row.token1AmountLabel
  let tokenAmountLabel = row.tokenAmountLabel

  if (token0 && token1 && token0 !== "—" && token1 !== "—") {
    tokenAmountLabel = `${token0} / ${token1}`
  } else if (!tokenAmountLabel || isUsdMirroredTokenLabel({ ...row, tokenSymbol: token0Symbol, tokenAmountLabel })) {
    const usd = row.amountUsd ?? parseCompactUsdLabel(row.amountLabel)
    if (usd != null) {
      const absUsd = Math.abs(usd)
      const t0 = tokenAmountFromUsd(absUsd * token0Weight, token0Symbol)
      const t1 = tokenAmountFromUsd(absUsd * token1Weight, token1Symbol)
      tokenAmountLabel = `${t0} / ${t1}`
    }
  }

  const usd = row.amountUsd ?? parseCompactUsdLabel(row.amountLabel)

  return {
    ...row,
    tokenSymbol: row.tokenSymbol ?? token0Symbol,
    tokenSymbolSecondary: row.tokenSymbolSecondary ?? token1Symbol,
    token0AmountLabel: token0 ?? tokenAmountLabel?.split("/")[0]?.trim(),
    token1AmountLabel: token1 ?? tokenAmountLabel?.split("/")[1]?.trim(),
    tokenAmountLabel,
    amountUsd: usd ?? undefined,
  }
}
