"use client"

import * as React from "react"
import { TokenIcon } from "@/app/components/token-icon"
import type { DetailTransactionRow } from "@/app/lib/detail-page/transaction-history"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { useCanonicalPriceFor } from "@/app/lib/prices/token-prices-context"
import { cn } from "@/lib/utils"
import {
  resolvePoolTokenAmounts,
  resolvePoolUsdValue,
  resolveTransactionTokenDisplay,
  resolveTransactionUsdValue,
  type TransactionPriceContext,
} from "@/app/lib/detail-page/transaction-display"

const AMOUNT_CLASS = "min-w-0 font-data text-[14px] font-normal tabular-nums tracking-normal text-foreground"

function useTransactionPriceContext(context: Record<string, string> = {}): TransactionPriceContext {
  const getLivePriceUsd = useCanonicalPriceFor()
  const token0Weight = context.token0Weight ? Number(context.token0Weight) : undefined
  const token1Weight = context.token1Weight ? Number(context.token1Weight) : undefined
  return React.useMemo(
    () => ({
      getLivePriceUsd,
      token0Weight: Number.isFinite(token0Weight) ? token0Weight : undefined,
      token1Weight: Number.isFinite(token1Weight) ? token1Weight : undefined,
    }),
    [getLivePriceUsd, token0Weight, token1Weight],
  )
}

function EmptyAlign() {
  return (
    <div className="flex w-full items-center justify-start">
      <span className={cn(AMOUNT_CLASS, "text-muted-foreground")}>—</span>
    </div>
  )
}

function TokenAmountWithIcon({ symbol, amount }: { symbol: string; amount: string }) {
  return (
    <div className="flex w-full items-center justify-start gap-1.5">
      <TokenIcon symbol={symbol} size="sm" className="size-5 shrink-0" />
      <span className={AMOUNT_CLASS}>{amount}</span>
    </div>
  )
}

export function TransactionTokenCell({
  row,
  priceContext,
  reconcileToLiveUsd = false,
}: {
  row: DetailTransactionRow
  priceContext?: TransactionPriceContext
  reconcileToLiveUsd?: boolean
}) {
  const token = resolveTransactionTokenDisplay(row, priceContext, reconcileToLiveUsd)
  if (!token) return <EmptyAlign />

  return <TokenAmountWithIcon symbol={token.symbol} amount={`${token.amount} ${token.symbol}`} />
}

export function TransactionPoolTokenCell({
  row,
  leg,
  token0Symbol,
  token1Symbol,
  priceContext,
}: {
  row: DetailTransactionRow
  leg: "token0" | "token1"
  token0Symbol: string
  token1Symbol: string
  priceContext?: TransactionPriceContext
}) {
  const { token0Amount, token1Amount } = resolvePoolTokenAmounts(row, token0Symbol, token1Symbol, priceContext)
  const amount = leg === "token0" ? token0Amount : token1Amount
  const symbol = leg === "token0" ? token0Symbol : token1Symbol

  if (!amount || amount === "—") return <EmptyAlign />
  return <TokenAmountWithIcon symbol={symbol} amount={amount} />
}

export function TransactionUsdCell({
  row,
  priceContext,
  poolSymbols,
  reconcileToLiveUsd = false,
}: {
  row: DetailTransactionRow
  priceContext?: TransactionPriceContext
  poolSymbols?: { token0: string; token1: string }
  reconcileToLiveUsd?: boolean
}) {
  const { compact } = useCurrency()
  const usdValue = poolSymbols
    ? resolvePoolUsdValue(row, poolSymbols.token0, poolSymbols.token1, priceContext)
    : resolveTransactionUsdValue(row, priceContext, reconcileToLiveUsd)

  if (usdValue == null) return <EmptyAlign />

  return (
    <div className="flex w-full items-center justify-start">
      <span className={cn(AMOUNT_CLASS, "text-muted-foreground")}>{compact(usdValue)}</span>
    </div>
  )
}

export function useDetailTransactionPriceContext(context: Record<string, string> = {}) {
  return useTransactionPriceContext(context)
}

/** Pool / legacy combined cell — prefer split columns on pool preset. */
export function TransactionAmountCell({
  row,
  priceContext,
}: {
  row: DetailTransactionRow
  priceContext?: TransactionPriceContext
}) {
  return (
    <div className="flex w-full items-center justify-start gap-3">
      <TransactionTokenCell row={row} priceContext={priceContext} />
      <TransactionUsdCell row={row} priceContext={priceContext} />
    </div>
  )
}
