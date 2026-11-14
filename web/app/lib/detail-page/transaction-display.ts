import type { DetailTransactionRow } from "@/app/lib/detail-page/transaction-history"
import { canonicalPriceUsd } from "@/app/lib/prices/canonical"

/** Format a token quantity for transaction tables (commas, sane precision). */
export function formatDetailTokenAmount(value: number): string {
  if (!Number.isFinite(value)) return "0"
  const abs = Math.abs(value)
  const digits = abs >= 1_000 ? 2 : abs >= 1 ? 4 : 6
  return abs.toLocaleString("en-US", { minimumFractionDigits: 0, maximumFractionDigits: digits })
}

const COMPACT_USD_RE = /^(<?)([+-]?)\$([\d,]+(?:\.\d+)?)([BMK]?)$/

/** Parse a compact USD label (e.g. "$37.50K", "-$1.2K") back to a USD number. */
export function parseCompactUsdLabel(label: string): number | null {
  const trimmed = label.trim().replace(/^\+/, "")
  const match = COMPACT_USD_RE.exec(trimmed)
  if (!match) return null
  const [, lessThan, sign, digits, suffix] = match
  if (lessThan) return null
  const multiplier = suffix === "B" ? 1_000_000_000 : suffix === "M" ? 1_000_000 : suffix === "K" ? 1_000 : 1
  const usd = Number(digits.replace(/,/g, "")) * multiplier
  if (!Number.isFinite(usd)) return null
  return sign === "-" ? -usd : usd
}

function compactUsdDigits(label: string): string {
  return label.replace(/^\$/, "").replace(/,/g, "").trim()
}

/** True when tokenAmountLabel is just the USD compact string without "$". */
export function isUsdMirroredTokenLabel(row: DetailTransactionRow): boolean {
  if (!row.tokenAmountLabel || !row.amountLabel.startsWith("$")) return false
  return compactUsdDigits(row.amountLabel) === row.tokenAmountLabel.replace(/,/g, "").trim()
}

export type TransactionPriceContext = {
  /** Frozen seed price for bootstrapping token qty from historical USD. */
  seedPriceUsd?: number
  /** Live oracle price for USD valuation at render time. */
  getLivePriceUsd?: (symbol: string) => number | undefined
  /** Pool constituent weight split when bootstrapping paired amounts (defaults 0.5/0.5). */
  token0Weight?: number
  token1Weight?: number
}

/** Price used to turn a recorded USD amount into a token quantity: the override, else the live price. */
export function seedPriceUsdForSymbol(symbol: string, seedOverride?: number): number {
  if (seedOverride != null && seedOverride > 0) return seedOverride
  return canonicalPriceUsd(symbol) ?? 1
}

function livePriceUsdForSymbol(symbol: string, ctx?: TransactionPriceContext): number {
  const live = ctx?.getLivePriceUsd?.(symbol)
  if (live != null && live > 0) return live
  return canonicalPriceUsd(symbol) ?? seedPriceUsdForSymbol(symbol)
}

function parseTokenQuantity(label: string): number | null {
  const trimmed = label.replace(/,/g, "").trim()
  if (!trimmed || trimmed === "—") return null
  const match = /^(-?)(\d+(?:\.\d+)?)([KMB])?$/i.exec(trimmed)
  if (!match) {
    const qty = Number(trimmed)
    return Number.isFinite(qty) ? qty : null
  }
  const suffix = match[3]?.toUpperCase()
  const multiplier = suffix === "B" ? 1_000_000_000 : suffix === "M" ? 1_000_000 : suffix === "K" ? 1_000 : 1
  const qty = Number(match[2]) * multiplier
  if (!Number.isFinite(qty)) return null
  return match[1] === "-" ? -qty : qty
}

function isPairedPoolRow(row: DetailTransactionRow): boolean {
  const t0 = row.token0AmountLabel
  const t1 = row.token1AmountLabel
  if (t0 && t1 && t0 !== "—" && t1 !== "—") return true
  return Boolean(row.tokenSymbolSecondary && row.tokenAmountLabel?.includes("/"))
}

function signedUsdValue(usd: number, row: DetailTransactionRow): number {
  const negative = row.amountLabel.trim().startsWith("-")
  return negative ? -Math.abs(usd) : Math.abs(usd)
}

export function tokenAmountFromUsd(usd: number, symbol: string, seedPriceOverride?: number): string {
  const price = seedPriceUsdForSymbol(symbol, seedPriceOverride)
  return formatDetailTokenAmount(Math.abs(usd) / price)
}

function usdValueFromTokenAmount(
  tokenAmountLabel: string,
  symbol: string,
  ctx?: TransactionPriceContext,
): number | null {
  const qty = parseTokenQuantity(tokenAmountLabel)
  if (qty == null) return null
  return qty * livePriceUsdForSymbol(symbol, ctx)
}

export function resolveTransactionTokenDisplay(
  row: DetailTransactionRow,
  opts?: TransactionPriceContext,
  reconcileToLiveUsd = false,
): { amount: string; symbol: string; secondaryAmount?: string; secondarySymbol?: string } | null {
  const symbol = row.tokenSymbol
  if (!symbol) return null

  // Debt/asset feed: the transaction record stores only USD, so any baked token amount is a
  // reconstruction at a FROZEN seed price that will not reconcile with the live-priced USD column
  // (a $2,471 WETH borrow bootstrapped at the $1,934 fixture reads "1.2776 WETH", which then
  // re-values to ~$3.1K). Re-derive the quantity from the recorded USD at the SAME live price the
  // USD cell uses, so token qty × price === recorded USD — matching the dashboard debt row.
  if (reconcileToLiveUsd && !isPairedPoolRow(row)) {
    const usd = row.amountUsd ?? parseCompactUsdLabel(row.amountLabel)
    if (usd != null) {
      return { amount: formatDetailTokenAmount(Math.abs(usd) / livePriceUsdForSymbol(symbol, opts)), symbol }
    }
  }

  if (row.tokenAmountLabel && !isUsdMirroredTokenLabel(row)) {
    if (row.tokenSymbolSecondary && row.tokenAmountLabel.includes("/")) {
      const [primary, secondary] = row.tokenAmountLabel.split("/").map((part) => part.trim())
      if (primary && secondary && primary !== "—" && secondary !== "—") {
        return {
          amount: primary,
          symbol,
          secondaryAmount: secondary,
          secondarySymbol: row.tokenSymbolSecondary,
        }
      }
    }
    return { amount: row.tokenAmountLabel, symbol }
  }

  const embedded = row.amountLabel.match(/^([+-]?[\d,]+(?:\.\d+)?)\s+([A-Za-z0-9.+-]+)$/)
  if (embedded && embedded[2] === symbol) {
    return { amount: embedded[1]!.replace(/^\+/, ""), symbol }
  }

  const usd = row.amountUsd ?? parseCompactUsdLabel(row.amountLabel)
  if (usd != null) {
    return { amount: tokenAmountFromUsd(usd, symbol, opts?.seedPriceUsd), symbol }
  }

  return null
}

export function resolvePoolTokenAmounts(
  row: DetailTransactionRow,
  token0Symbol: string,
  token1Symbol: string,
  opts?: TransactionPriceContext,
): { token0Amount: string | null; token1Amount: string | null } {
  const t0 = row.token0AmountLabel
  const t1 = row.token1AmountLabel
  if (t0 && t1 && t0 !== "—" && t1 !== "—") {
    return { token0Amount: t0, token1Amount: t1 }
  }

  const paired = resolveTransactionTokenDisplay(row, opts)
  if (paired?.secondaryAmount && paired.secondarySymbol) {
    return { token0Amount: paired.amount, token1Amount: paired.secondaryAmount }
  }

  const usd = row.amountUsd ?? parseCompactUsdLabel(row.amountLabel)
  if (usd != null) {
    const w0 = opts?.token0Weight ?? 0.5
    const w1 = opts?.token1Weight ?? 0.5
    const absUsd = Math.abs(usd)
    return {
      token0Amount: tokenAmountFromUsd(absUsd * w0, token0Symbol, opts?.seedPriceUsd),
      token1Amount: tokenAmountFromUsd(absUsd * w1, token1Symbol, opts?.seedPriceUsd),
    }
  }

  return { token0Amount: null, token1Amount: null }
}

export function resolvePoolUsdValue(
  row: DetailTransactionRow,
  token0Symbol: string,
  token1Symbol: string,
  opts?: TransactionPriceContext,
): number | null {
  const { token0Amount, token1Amount } = resolvePoolTokenAmounts(row, token0Symbol, token1Symbol, opts)
  if (!token0Amount || !token1Amount) return null

  const usd0 = usdValueFromTokenAmount(token0Amount, token0Symbol, opts)
  const usd1 = usdValueFromTokenAmount(token1Amount, token1Symbol, opts)
  if (usd0 == null || usd1 == null) return null
  return signedUsdValue(usd0 + usd1, row)
}

export function resolveTransactionUsdValue(
  row: DetailTransactionRow,
  opts?: TransactionPriceContext,
  reconcileToLiveUsd = false,
): number | null {
  const trimmed = row.amountLabel.trim()
  if (trimmed.includes("→") || trimmed.endsWith("x") || trimmed.endsWith("×")) return null

  // Debt/asset feed: show the recorded USD of the action (frozen at execution) instead of a
  // re-valuation of a seed-bootstrapped token quantity, which overshoots the record. Paired with
  // the token cell's live-price reconstruction, the row reconciles: qty × price === this USD.
  if (reconcileToLiveUsd && !isPairedPoolRow(row)) {
    const usd = row.amountUsd ?? parseCompactUsdLabel(row.amountLabel)
    if (usd != null) return signedUsdValue(usd, row)
  }

  if (isPairedPoolRow(row) && row.tokenSymbol && row.tokenSymbolSecondary) {
    const poolUsd = resolvePoolUsdValue(row, row.tokenSymbol, row.tokenSymbolSecondary, opts)
    if (poolUsd != null) return poolUsd
  }

  const embedded = trimmed.match(/^([+-]?[\d,]+(?:\.\d+)?)\s+([A-Za-z0-9.+-]+)$/)
  if (embedded) {
    const symbol = row.tokenSymbol ?? embedded[2]
    if (symbol) {
      const usd = usdValueFromTokenAmount(embedded[1]!.replace(/^[+-]/, ""), symbol, opts)
      if (usd != null) return signedUsdValue(usd, row)
    }
  }

  const token = resolveTransactionTokenDisplay(row, opts)
  if (token?.amount && row.tokenSymbol && !token.amount.endsWith("x") && !token.amount.endsWith("×")) {
    const usd = usdValueFromTokenAmount(token.amount, row.tokenSymbol, opts)
    if (usd != null) return signedUsdValue(usd, row)
  }

  return null
}
