"use client"

import { TableHeaderHint } from "@/app/components/table-header-hint"
import { Suspense, type ReactNode } from "react"
import Link from "next/link"
import { Skeleton } from "@/components/ui/skeleton"
import { ActionIcon } from "@/app/components/action-icon"
import { Button } from "@/components/ui/button"
import { TokenIcon } from "@/app/components/token-icon"
import { DesktopTableSurface, HoverActionGroup, ScrollableTable } from "@/app/components/market-table-primitives"
import { useAmountDisplayPreferences } from "@/app/components/display-preferences"
import {} from "@/app/components/market-card-primitives"
import { useCanonicalPriceFor } from "@/app/lib/prices/token-prices-context"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { buildDashboardWalletBalanceRows } from "@/app/lib/swap-system"
import { useConvexProductWalletBalances } from "@/app/lib/swap-system/use-convex-wallet-balances"
import type { UserAssetBalance } from "@/app/lib/swap-system"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import {
  DASHBOARD_TABLE_REFERENCE_PX,
  TABLE_ACTION_BUTTON,
  TABLE_BODY_ROW,
  TABLE_CELL_NUMERIC,
  TABLE_CELL_PADDING,
  TABLE_CELL_PADDING_TRAILING,
  TABLE_CELL_PRIMARY,
  TABLE_CELL_SECONDARY,
  TABLE_HEADER_CELL,
  TABLE_HEADER_ROW,
  TABLE_ROW_HOVER_BG,
  TABLE_ROW_HOVER_RIGHT,
  formatTableHeaderLabel,
  tableColumnLayout,
  tableStickyCell,
} from "@/app/lib/ui/table-row-hover"
import { cn } from "@/lib/utils"
import { TokenTickerPriceLabel } from "@/app/lib/ui/token-ticker-price-label"

/** Adaptive token-amount precision so `amount × unit price` reconciles with the USD value. */
function formatAvailableAmount(value: number, symbol: string) {
  const maximumFractionDigits = value >= 100 ? 2 : value >= 1 ? 4 : 6
  return `${value.toLocaleString("en-US", { maximumFractionDigits })} ${symbol}`
}

/** Per-row CTA for an available balance (Deposit on lend, Multiply on multiply, …). */
type AvailableRowAction = {
  /** ActionIcon label, e.g. "deposit" | "multiply". */
  icon: string
  /** Already-translated button text. */
  label: string
  href: (row: { assetId: string; symbol: string }) => string
}

function AvailableActionButton({ href, label, icon }: { href: string; label: string; icon: string }) {
  return (
    <HoverActionGroup className="gap-2">
      <Button asChild size="table" variant="table-primary" className={TABLE_ACTION_BUTTON}>
        <Link href={href}>
          <ActionIcon label={icon} />
          {label}
        </Link>
      </Button>
    </HoverActionGroup>
  )
}

const AVAILABLE_LAYOUT = tableColumnLayout(["identityCompact", "metric"], {
  referenceWidth: DASHBOARD_TABLE_REFERENCE_PX,
})
const AVAILABLE_WITH_ACTION_LAYOUT = tableColumnLayout(["identityCompact", "metric", "actionCompact"], {
  referenceWidth: DASHBOARD_TABLE_REFERENCE_PX,
})
const MASK = "••••"

/**
 * Idle "available to use" funds for a product — the buckets that were moved off the
 * Wallet tab (which now shows only unallocated funds). Rendering them here keeps the
 * money visible on the product it belongs to, and lets the global Net Value reconcile
 * with the per-tab totals. Renders nothing when the wallet has no such balance.
 */
export function ProductAvailableCard({
  walletId,
  sourceTypes,
  allowedAssetIds,
  title,
  action,
}: {
  walletId: string
  sourceTypes: ReadonlyArray<UserAssetBalance["sourceType"]>
  /** Optional product catalog filter for shared wallet rows. */
  allowedAssetIds?: ReadonlySet<string>
  /** Already-translated heading (translate at the call site so i18n parity can see the key). */
  title: string
  /** Optional per-row CTA (e.g. Deposit / Multiply). */
  action?: AvailableRowAction
}) {
  const { t } = useTranslation()
  const { exact } = useCurrency()
  const { showDollarAmounts } = useAmountDisplayPreferences()
  const priceFor = useCanonicalPriceFor()
  const balances = useConvexProductWalletBalances(walletId)
  // Do not invoke buildDashboardWalletBalanceRows without an explicit result: its
  // default is a test fixture, and a loading Convex query must never render demo money.
  if (balances === undefined) return null
  const allow = new Set(sourceTypes)
  const matchingRows = buildDashboardWalletBalanceRows({ walletId, balances, priceFor }).filter(
    (row) => allow.has(row.sourceType) && (!allowedAssetIds || allowedAssetIds.has(row.assetId)),
  )
  // Prefer canonical unallocated wallet rows when a legacy product-available row for
  // the same asset still exists. This prevents one balance from appearing twice and
  // prevents stale product buckets from masking the real wallet amount.
  const canonicalAssetIds = new Set(matchingRows.filter((row) => row.sourceType === "wallet").map((row) => row.assetId))
  const rows = matchingRows.filter((row) => row.sourceType === "wallet" || !canonicalAssetIds.has(row.assetId))
  if (rows.length === 0) return null
  const total = rows.reduce((sum, row) => sum + row.valueUsd, 0)
  const m = (value: string) => (showDollarAmounts ? value : MASK)

  return (
    <section className="min-w-0 space-y-3">
      <div className="flex items-baseline justify-between gap-3">
        <h3 className="text-[18px] font-medium tracking-tight text-foreground md:text-[20px]">{title}</h3>
        <span className="font-data text-[15px] tabular-nums text-foreground">{m(exact(total))}</span>
      </div>

      <DesktopTableSurface className="!rounded-none">
        <ScrollableTable layout={action ? AVAILABLE_WITH_ACTION_LAYOUT : AVAILABLE_LAYOUT}>
          <thead>
            <tr className={TABLE_HEADER_ROW}>
              <th className={cn(TABLE_HEADER_CELL, "px-4", tableStickyCell("header"))}>
                <TableHeaderHint hint={t("A token in your wallet you can put to work here.")}>
                  {formatTableHeaderLabel(t("Asset"))}
                </TableHeaderHint>
              </th>
              <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                <TableHeaderHint hint={t("Your wallet balance of this token, ready to use.")}>
                  {formatTableHeaderLabel(t("Available"))}
                </TableHeaderHint>
              </th>
              {action ? (
                <th className={cn(TABLE_HEADER_CELL, "px-4 pr-5 text-right")}>
                  <span className="sr-only">{action.label}</span>
                </th>
              ) : null}
            </tr>
          </thead>
          <tbody className="divide-y divide-border dark:divide-white/6">
            {rows.map((row) => (
              <tr key={row.id} className={`${TABLE_BODY_ROW} group`}>
                <td className={cn(TABLE_CELL_PADDING, "pl-6", tableStickyCell("body"))}>
                  <div className="flex min-w-0 items-center gap-3">
                    <TokenIcon symbol={row.symbol} size="table" />
                    <div className="min-w-0">
                      <div className={cn("truncate", TABLE_CELL_PRIMARY)}>{row.name}</div>
                      <div className={cn("truncate tabular-nums", TABLE_CELL_SECONDARY)}>
                        <TokenTickerPriceLabel symbol={row.symbol} />
                      </div>
                    </div>
                  </div>
                </td>
                <td className={cn(action ? TABLE_CELL_PADDING : TABLE_CELL_PADDING_TRAILING, TABLE_ROW_HOVER_BG)}>
                  <div className={TABLE_CELL_NUMERIC}>{m(formatAvailableAmount(row.amount, row.symbol))}</div>
                  <div className={cn(TABLE_CELL_SECONDARY, "tabular-nums")}>{m(exact(row.valueUsd))}</div>
                </td>
                {action ? (
                  <td className={cn(TABLE_CELL_PADDING_TRAILING, "text-right", TABLE_ROW_HOVER_RIGHT)}>
                    <AvailableActionButton href={action.href(row)} label={action.label} icon={action.icon} />
                  </td>
                ) : null}
              </tr>
            ))}
          </tbody>
        </ScrollableTable>
      </DesktopTableSurface>
    </section>
  )
}

const ACCOUNT_MODULE_FALLBACK_HEIGHT = {
  borrow: "h-[520px]",
} as const

export function AccountModuleBoundary({
  children,
  product,
}: {
  children: ReactNode
  product: keyof typeof ACCOUNT_MODULE_FALLBACK_HEIGHT
}) {
  return (
    <Suspense
      fallback={
        <Skeleton
          className={cn("w-full rounded-radius-md", ACCOUNT_MODULE_FALLBACK_HEIGHT[product])}
          data-testid={`${product}-account-module-skeleton`}
        />
      }
    >
      {children}
    </Suspense>
  )
}
