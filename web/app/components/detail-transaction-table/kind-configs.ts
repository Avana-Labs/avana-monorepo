import type { DetailTransactionRow } from "@/app/lib/detail-page/transaction-history"

export type TransactionKindConfig = {
  labels: Record<string, string>
  tones: Record<string, string>
  describeFor?: (row: DetailTransactionRow, context: Record<string, string>) => string
}

const INFLOW_TONE = "text-success"
const OUTFLOW_TONE = "text-rose-600 dark:text-rose-400"
const NEUTRAL_TONE = "text-muted-foreground"
const WARNING_TONE = "text-amber-600 dark:text-amber-400"

export const LEND_KIND_CONFIG: TransactionKindConfig = {
  labels: {
    supply: "Supply",
    withdraw: "Withdraw",
    rewards: "Rewards",
  },
  tones: {
    supply: INFLOW_TONE,
    withdraw: OUTFLOW_TONE,
    rewards: INFLOW_TONE,
  },
  describeFor: (row, { assetSymbol }) => {
    if (row.tokenSymbol && row.tokenAmountLabel) return `${row.tokenAmountLabel} ${row.tokenSymbol}`
    return `${assetSymbol} market`
  },
}

export const BORROW_ASSET_KIND_CONFIG: TransactionKindConfig = {
  labels: {
    supply: "Supply",
    withdraw: "Withdraw",
    borrow: "Borrow",
    repay: "Repay",
    rewards: "Rewards",
    liquidation: "Liquidation",
  },
  tones: {
    supply: INFLOW_TONE,
    withdraw: OUTFLOW_TONE,
    borrow: OUTFLOW_TONE,
    repay: INFLOW_TONE,
    rewards: INFLOW_TONE,
    liquidation: WARNING_TONE,
  },
  describeFor: (row, { assetSymbol }) => {
    if (row.tokenSymbol && row.tokenAmountLabel) return `${row.tokenAmountLabel} ${row.tokenSymbol}`
    return `${assetSymbol} market`
  },
}

export const BORROW_POOL_KIND_CONFIG: TransactionKindConfig = {
  labels: {
    supply: "Pledge",
    withdraw: "Remove",
    borrow: "Borrow",
    repay: "Repay",
    rewards: "Claim",
    liquidation: "Liquidation",
  },
  tones: {
    supply: INFLOW_TONE,
    withdraw: OUTFLOW_TONE,
    borrow: OUTFLOW_TONE,
    repay: INFLOW_TONE,
    rewards: INFLOW_TONE,
    liquidation: WARNING_TONE,
  },
}

export type DetailTransactionPreset = "standard" | "pool"

type DetailTransactionColumnId = "time" | "type" | "for" | "usd" | "token0" | "token1" | "wallet"

type DetailTransactionColumn = {
  id: DetailTransactionColumnId
  label: string
  align?: "left" | "right"
}

export const PRESET_COLUMNS: Record<DetailTransactionPreset, DetailTransactionColumn[]> = {
  standard: [
    { id: "time", label: "Time" },
    { id: "type", label: "Type" },
    { id: "for", label: "For", align: "right" },
    { id: "usd", label: "USD", align: "right" },
    { id: "wallet", label: "Wallet", align: "right" },
  ],
  // Uniswap-style: time, action, fiat, then each leg with its own column header.
  pool: [
    { id: "time", label: "Time" },
    { id: "type", label: "Type" },
    { id: "usd", label: "USD", align: "right" },
    { id: "token0", label: "token0", align: "right" },
    { id: "token1", label: "token1", align: "right" },
    { id: "wallet", label: "Wallet", align: "right" },
  ],
}

export function resolveColumnLabel(
  column: DetailTransactionColumn,
  context: Record<string, string>,
  fiatCode: string,
): string {
  if (column.id === "usd") return fiatCode
  if (column.id === "token0") return context.token0Symbol || "Token"
  if (column.id === "token1") return context.token1Symbol || "Token"
  return column.label
}

/** Never render a raw engine kind like "borrow" — fall back to a readable label. */
export function resolveTransactionKindLabel(config: TransactionKindConfig, kind: string): string {
  const mapped = config.labels[kind] ?? config.labels[kind.toLowerCase()]
  if (mapped) return mapped
  if (!kind) return kind
  return kind.replace(/[_-]+/g, " ").replace(/\b\w/g, (char) => char.toUpperCase())
}

export function resolveTransactionKindTone(config: TransactionKindConfig, kind: string): string | undefined {
  return config.tones[kind] ?? config.tones[kind.toLowerCase()]
}
