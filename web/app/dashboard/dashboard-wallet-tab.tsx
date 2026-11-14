"use client"

import Link from "next/link"
import { ActionIcon } from "@/app/components/action-icon"
import { ActionMetricHelp } from "@/app/components/action-page/action-metric-help"
import { TableHeaderHint } from "@/app/components/table-header-hint"
import { Button } from "@/components/ui/button"
import { TokenPairCell } from "@/app/borrow/components/atoms"
import { detailSectionStackClass } from "@/app/components/detail-page-primitives"
import { useAmountDisplayPreferences } from "@/app/components/display-preferences"
import {} from "@/app/components/market-card-primitives"
import { TokenIcon } from "@/app/components/token-icon"
import { DesktopTableSurface, ScrollableTable } from "@/app/components/market-table-primitives"
import { getTokenIconMeta } from "@/app/lib/token-icons"
import { borrowMarketDetailPath } from "@/app/lib/borrow-routes"
import { useBorrowSessionContextOptional } from "@/app/lib/avana-session/avana-sessions-context"
import {
  DASHBOARD_TABLE_REFERENCE_PX,
  TABLE_ACTION_BUTTON,
  TABLE_BODY_ROW,
  TABLE_CELL_CAPTION_UNCOLORED,
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
import { TickerPriceFlip } from "@/app/lib/ui/token-ticker-price-label"

const WALLET_TOKENS_LAYOUT = tableColumnLayout(
  [
    "identityCompact",
    "metric", // Balance
    "metricWide", // Value over P/L
    "actionCompact", // Swap
  ],
  { referenceWidth: DASHBOARD_TABLE_REFERENCE_PX },
)
const WALLET_POOLS_LAYOUT = tableColumnLayout(
  [
    "identityCompact",
    "compact", // LTV
    "compact", // Risk premium
    "metric", // Balance
  ],
  { referenceWidth: DASHBOARD_TABLE_REFERENCE_PX },
)
import {
  buildDashboardWalletBalanceRows,
  selectDashboardWalletValueRows,
  type DashboardWalletBalanceRow,
} from "@/app/lib/swap-system"
import type { UserAssetBalance } from "@/app/lib/swap-system"
import {
  useConvexClaimBasis,
  useConvexProductWalletBalances,
  useConvexWalletOnboardingSummary,
} from "@/app/lib/swap-system/use-convex-wallet-balances"
import { useCanonicalPriceFor } from "@/app/lib/prices/token-prices-context"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import type { BorrowAssetVisual } from "@/app/lib/data/borrow-domain"
import { formatLtvPct, formatRiskPremium, type BorrowSpokeId } from "@/app/lib/borrow-market-rows"

const DASH = "\u2014"
const MASK = "••••"

// Do not invent LP fee/status analytics — show dashes until live data exists.
function WalletMetricHeader({
  label,
  help,
  align = "left",
}: {
  label: string
  help: string
  align?: "left" | "right"
}) {
  return (
    <TableHeaderHint
      hint={help}
      className={cn("inline-flex items-center gap-1 whitespace-nowrap", align === "right" && "justify-end")}
    >
      {formatTableHeaderLabel(label)}
    </TableHeaderHint>
  )
}

function sectionCount(count: number, singular: string, plural: string) {
  return `${count} ${count === 1 ? singular : plural}`
}

function formatAssetAmount(amount: number, symbol: string) {
  const maximumFractionDigits = amount >= 100 ? 2 : amount >= 1 ? 3 : 4
  return `${amount.toLocaleString(undefined, { maximumFractionDigits })} ${symbol}`
}

function formatPoolAmount(amount: number) {
  return amount.toLocaleString(undefined, { maximumFractionDigits: 6 })
}

/**
 * Token P/L against the onboarding cost basis. Free starter tokens are granted at
 * a recorded price (`priceUsdAtClaim`); the dashboard values the balance live, so
 * P/L = current value − amount × grant price. Null when there's no recorded basis
 * (e.g. tokens acquired by swap, or still loading) — the cell shows a dash.
 */
function tokenPnl(
  row: DashboardWalletBalanceRow,
  priceUsdAtClaim: number | undefined,
): { pnlUsd: number; pnlPct: number } | null {
  if (!priceUsdAtClaim || priceUsdAtClaim <= 0 || row.amount <= 0) return null
  const costBasisUsd = row.amount * priceUsdAtClaim
  if (costBasisUsd <= 0) return null
  const pnlUsd = row.valueUsd - costBasisUsd
  return { pnlUsd, pnlPct: (pnlUsd / costBasisUsd) * 100 }
}

/**
 * Wallet-wide unrealized P/L: sum each token's live value − its onboarding cost basis, over
 * every row that has a recorded basis. LP/swapped rows without a basis contribute nothing. The
 * aggregate percentage is dollar-weighted (Σ pnl ÷ Σ basis), so it matches the headline figure.
 * Returns null when no row carries a basis — the tile then shows a dash rather than a fake $0.
 */
function sumWalletPnl(
  rows: ReadonlyArray<DashboardWalletBalanceRow>,
  basisFor: (assetId: string) => number | undefined,
): { pnlUsd: number; pnlPct: number } | null {
  let pnlUsd = 0
  let basisUsd = 0
  let hasBasis = false
  for (const row of rows) {
    const priceUsdAtClaim = basisFor(row.assetId)
    const pnl = tokenPnl(row, priceUsdAtClaim)
    if (!pnl || !priceUsdAtClaim) continue
    pnlUsd += pnl.pnlUsd
    basisUsd += row.amount * priceUsdAtClaim
    hasBasis = true
  }
  if (!hasBasis || basisUsd <= 0) return null
  return { pnlUsd, pnlPct: (pnlUsd / basisUsd) * 100 }
}

/** "Member since" tile: a compact month-year ("Aug 2026") from the onboarding timestamp. */
function formatMemberSince(sinceMs: number): string {
  return new Date(sinceMs).toLocaleDateString(undefined, { month: "short", year: "numeric" })
}

type DashboardBorrowMarketMeta = {
  listPremiumBps?: number
  spokeId?: BorrowSpokeId
  display?: { venue?: string }
}

type DashboardBorrowMarkets = Readonly<Record<string, DashboardBorrowMarketMeta>>

function toBorrowVisual(symbol: string): BorrowAssetVisual {
  const meta = getTokenIconMeta(symbol)
  return {
    symbol: meta.symbol,
    shortLabel: meta.symbol.slice(0, 4),
    bgClass: meta.bgClass,
    textClass: meta.textClass,
    iconUrl: meta.iconUrl,
  }
}

function lpPairVisuals(row: DashboardWalletBalanceRow): [BorrowAssetVisual, BorrowAssetVisual] | null {
  const pairLabel = row.name.replace(/\s*LP$/i, "")
  const parts = pairLabel
    .split("/")
    .map((part) => part.trim())
    .filter(Boolean)
  if (parts.length < 2) return null
  return [toBorrowVisual(parts[0]!), toBorrowVisual(parts[1]!)]
}

function PoolIdentity({ row, markets }: { row: DashboardWalletBalanceRow; markets?: DashboardBorrowMarkets }) {
  const visuals = lpPairVisuals(row)
  const detail = poolUiDetail(row, markets)
  if (!visuals) {
    return (
      <div className="flex min-w-0 items-center gap-3">
        <TokenIcon symbol={row.symbol} size="table" />
        <div className="flex min-w-0 flex-col">
          <div className={cn("truncate", TABLE_CELL_PRIMARY)} title={row.name}>
            {row.name}
          </div>
          <div className={cn("truncate", TABLE_CELL_SECONDARY)}>{detail.protocol}</div>
        </div>
      </div>
    )
  }

  return <TokenPairCell visuals={visuals} name={row.name} subtitle={detail.protocol} size="md" />
}

function poolDetailHref(row: DashboardWalletBalanceRow) {
  const poolId = poolIdForRow(row)
  return borrowMarketDetailPath(poolId)
}

function poolIdForRow(row: DashboardWalletBalanceRow) {
  return row.sourcePositionId ?? row.assetId.replace(/-lp$/i, "")
}

function poolUiDetail(row: DashboardWalletBalanceRow, markets?: DashboardBorrowMarkets) {
  const poolId = poolIdForRow(row)
  const venue = markets?.[poolId]?.display?.venue
  return { protocol: venue || row.sourceLabel }
}

export function resolvePoolRiskPremiumBps(
  row: DashboardWalletBalanceRow,
  markets?: DashboardBorrowMarkets,
): number | undefined {
  const poolId = poolIdForRow(row)
  const livePremium = markets?.[poolId]?.listPremiumBps
  return livePremium != null && Number.isFinite(livePremium) ? livePremium : undefined
}

function TokenUsdCell({ token, usd }: { token: string; usd?: string }) {
  return (
    <div className="flex flex-col items-start">
      <span className={cn(TABLE_CELL_NUMERIC)}>{token}</span>
      {usd ? <span className={TABLE_CELL_SECONDARY}>{usd}</span> : null}
    </div>
  )
}

function PoolBalanceCell({
  row,
  exact,
  mask,
}: {
  row: DashboardWalletBalanceRow
  exact: (usd: number) => string
  mask: (value: string) => string
}) {
  if (row.unitPriceUsd && row.unitPriceUsd > 0) {
    return <TokenUsdCell token={mask(`${formatPoolAmount(row.amount)} LP`)} usd={mask(exact(row.valueUsd))} />
  }

  return <TokenUsdCell token={mask(exact(row.valueUsd))} />
}

function PoolLtvCell({ row, mask }: { row: DashboardWalletBalanceRow; mask: (value: string) => string }) {
  const value = row.ltvPct != null && Number.isFinite(row.ltvPct) ? formatLtvPct(row.ltvPct) : DASH
  return <span className={cn(TABLE_CELL_NUMERIC)}>{mask(value)}</span>
}

function PoolRiskPremiumCell({
  row,
  markets,
  mask,
}: {
  row: DashboardWalletBalanceRow
  markets?: DashboardBorrowMarkets
  mask: (value: string) => string
}) {
  const bps = resolvePoolRiskPremiumBps(row, markets)
  return <span className={cn(TABLE_CELL_NUMERIC)}>{mask(bps != null ? formatRiskPremium(bps) : DASH)}</span>
}

function WalletMetric({
  label,
  value,
  description,
  tone = "neutral",
}: {
  label: string
  value: string
  description: string
  tone?: "up" | "down" | "neutral"
}) {
  const toneClass = tone === "up" ? "text-success" : tone === "down" ? "text-danger" : "text-foreground"
  return (
    <article className="min-w-0 space-y-1.5">
      <div className="flex items-center gap-1.5">
        <span className="text-[13px] text-muted-foreground">{label}</span>
        <ActionMetricHelp text={description} topic={label} />
      </div>
      <div
        className={cn(
          "font-data text-[clamp(1.35rem,1.8vw,1.95rem)] font-medium leading-none tracking-[-0.02em]",
          toneClass,
        )}
      >
        {value}
      </div>
    </article>
  )
}

/** Compact P/L line shown under Value on desktop, or as a full mobile stat value. */
function PnlLine({
  row,
  priceUsdAtClaim,
  exact,
  showBalance,
  variant = "caption",
}: {
  row: DashboardWalletBalanceRow
  priceUsdAtClaim: number | undefined
  exact: (usd: number) => string
  showBalance: boolean
  /** `value` matches MarketMobileStatRow (15px); `caption` stays under desktop Value. */
  variant?: "caption" | "value"
}) {
  const sizeClass = variant === "value" ? "text-[15px] font-normal tracking-normal" : TABLE_CELL_CAPTION_UNCOLORED
  const pnl = tokenPnl(row, priceUsdAtClaim)
  if (!pnl) return <span className={cn(sizeClass, "text-muted-foreground")}>{showBalance ? DASH : MASK}</span>
  if (!showBalance) return <span className={cn(sizeClass, "text-muted-foreground")}>{MASK}</span>

  const positive = pnl.pnlUsd > 0
  const negative = pnl.pnlUsd < 0
  const toneClass = positive ? "text-success" : negative ? "text-danger" : "text-muted-foreground"
  const arrow = positive ? "▲" : negative ? "▼" : "•"
  const sign = positive ? "+" : negative ? "-" : ""
  return (
    <span className={cn(sizeClass, "tabular-nums", toneClass)}>
      {arrow} {sign}
      {exact(Math.abs(pnl.pnlUsd))} · {Math.abs(pnl.pnlPct).toFixed(2)}%
    </span>
  )
}

/** Value stacked over its P/L — the wallet's own live valuation plus P/L vs grant. */
function ValueWithPnl({
  row,
  priceUsdAtClaim,
  exact,
  showBalance,
}: {
  row: DashboardWalletBalanceRow
  priceUsdAtClaim: number | undefined
  exact: (usd: number) => string
  showBalance: boolean
}) {
  return (
    <div className="flex flex-col items-start gap-0.5">
      <span className={TABLE_CELL_NUMERIC}>{showBalance ? exact(row.valueUsd) : MASK}</span>
      <PnlLine row={row} priceUsdAtClaim={priceUsdAtClaim} exact={exact} showBalance={showBalance} />
    </div>
  )
}

/** Per-row Swap CTA — table-styled button (matches the lend/borrow tables) that
 *  deep-links to the swap flow with this token preselected. */
function SwapAction({ assetId, label }: { assetId: string; label: string }) {
  return (
    <div className="flex justify-end">
      <Button asChild size="table" variant="table-secondary" className={TABLE_ACTION_BUTTON}>
        <Link href={`/swap?from=${encodeURIComponent(assetId)}`} aria-label={label}>
          <ActionIcon label="swap" />
          {label}
        </Link>
      </Button>
    </div>
  )
}

/**
 * "Wallet Value" = the value of funds currently available to the wallet owner. Callers pass rows
 * already filtered to wallet-accessible balances, so this is a plain sum of those holdings.
 */
export function sumWalletValueUsd(rows: ReadonlyArray<{ valueUsd: number; sourceLabel: string }>): number {
  return rows.reduce((total, row) => total + row.valueUsd, 0)
}

export function DashboardWalletTab({ walletId, balances }: { walletId: string; balances?: UserAssetBalance[] }) {
  const { showDollarAmounts } = useAmountDisplayPreferences()
  const { exact, price } = useCurrency()
  const { t } = useTranslation()
  const borrowSession = useBorrowSessionContextOptional()
  // The Wallet tab shows unallocated/free funds plus product buckets that are available again
  // after a withdrawal. Prefer the canonical liquid row when a product also mirrors that asset,
  // so Lend withdrawals do not appear twice while returned Borrow LPs remain visible as Pools.
  const convexBalances = useConvexProductWalletBalances(balances === undefined ? walletId : null)
  const effectiveBalances = balances ?? convexBalances ?? undefined
  const claimBasis = useConvexClaimBasis(balances === undefined ? walletId : null)
  const basisFor = (assetId: string) => claimBasis?.[assetId.toLowerCase()]
  const priceFor = useCanonicalPriceFor()
  const rows = selectDashboardWalletValueRows(
    buildDashboardWalletBalanceRows({ walletId, balances: effectiveBalances, priceFor }),
  )
  const tokens = rows.filter((row) => !row.isLpToken)
  const lps = rows.filter((row) => row.isLpToken)
  const totalWalletUsd = sumWalletValueUsd(rows)
  const walletPnl = sumWalletPnl(rows, basisFor)
  const onboarding = useConvexWalletOnboardingSummary(balances === undefined ? walletId : null)
  const memberSince = typeof onboarding?.sinceMs === "number" ? formatMemberSince(onboarding.sinceMs) : null
  const boost = typeof onboarding?.boost === "number" ? onboarding.boost : null
  const m = (value: string) => (showDollarAmounts ? value : MASK)
  // Masking a colored P/L would leak the sign through the tone, so a hidden P/L falls back to neutral.
  const pnlSign = walletPnl && walletPnl.pnlUsd > 0 ? "+" : walletPnl && walletPnl.pnlUsd < 0 ? "-" : ""
  const pnlTone: "up" | "down" | "neutral" =
    !showDollarAmounts || !walletPnl
      ? "neutral"
      : walletPnl.pnlUsd > 0
        ? "up"
        : walletPnl.pnlUsd < 0
          ? "down"
          : "neutral"

  return (
    <section id="dashboard-wallet" className={detailSectionStackClass} aria-label={t("Wallet balances")}>
      <section className="space-y-4">
        <h2 className="text-[20px] font-medium tracking-[-0.01em] text-foreground md:text-[20px]">
          {t("Wallet Overview")}
        </h2>
        <div className="grid w-full grid-cols-2 gap-x-5 gap-y-6 lg:grid-cols-4 xl:gap-x-8">
          <WalletMetric
            label={t("Wallet Value")}
            value={m(exact(totalWalletUsd))}
            description="Live value of your free, unallocated wallet funds — everything not committed to Lend or Borrow."
          />
          <WalletMetric
            label={t("Unrealized P/L")}
            value={walletPnl ? m(`${pnlSign}${exact(Math.abs(walletPnl.pnlUsd))}`) : DASH}
            tone={pnlTone}
            description="Change in your wallet tokens' value since onboarding: current live value minus the granted cost basis."
          />
          <WalletMetric
            label={t("Avana Boost")}
            value={boost != null ? `${boost.toFixed(2)}x` : DASH}
            description="Your Avana rank — a per-wallet standing that boosts your edge across Lend, Borrow, and Swap. The higher it climbs, the more it unlocks."
          />
          <WalletMetric
            label={t("Member since")}
            value={memberSince ?? DASH}
            description="When you completed onboarding and joined Avana."
          />
        </div>
      </section>

      <WalletBalanceSection
        title={t("Tokens")}
        rows={tokens}
        exact={exact}
        price={price}
        t={t}
        showBalance={showDollarAmounts}
        basisFor={basisFor}
      />
      <PoolsBalanceSection
        title={t("Pools")}
        rows={lps}
        exact={exact}
        t={t}
        showBalance={showDollarAmounts}
        markets={borrowSession?.state.markets}
      />
    </section>
  )
}

function WalletBalanceSection({
  title,
  rows,
  exact,
  price,
  t,
  showBalance,
  basisFor,
}: {
  title: string
  rows: DashboardWalletBalanceRow[]
  exact: (usd: number) => string
  price: (usd: number) => string
  t: (key: string) => string
  showBalance: boolean
  basisFor: (assetId: string) => number | undefined
}) {
  const m = (value: string) => (showBalance ? value : MASK)
  return (
    <section className="min-w-0">
      <div className="mb-4">
        <h3 className="text-[18px] font-medium tracking-tight text-foreground md:text-[20px]">{title}</h3>
        <p className="mt-1 text-[13px] text-muted-foreground">{sectionCount(rows.length, "token", "tokens")}</p>
      </div>

      <DesktopTableSurface className="!rounded-none">
        <ScrollableTable layout={WALLET_TOKENS_LAYOUT}>
          <thead>
            <tr className={TABLE_HEADER_ROW}>
              <th className={cn(TABLE_HEADER_CELL, "px-4", tableStickyCell("header"))}>
                <WalletMetricHeader label={t("Asset")} help={t("A token held directly in your connected wallet.")} />
              </th>
              <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                <WalletMetricHeader label={t("Balance")} help={t("The amount of this token in your wallet.")} />
              </th>
              <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                <WalletMetricHeader label={t("Value")} help={t("The token balance valued at its live price.")} />
              </th>
              <th className={cn(TABLE_HEADER_CELL, "px-4 pr-5 text-right")}>
                <span className="sr-only">{t("Swap")}</span>
              </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-border dark:divide-white/6">
            {rows.map((row) => (
              <tr key={row.id} className={`${TABLE_BODY_ROW} group`}>
                <td className={cn(TABLE_CELL_PADDING, "pl-6", tableStickyCell("body"))}>
                  <div className="flex min-w-0 items-center gap-3">
                    <TokenIcon symbol={row.symbol} size="table" />
                    <div className="min-w-0">
                      <div className={cn("truncate", TABLE_CELL_PRIMARY)} title={row.name}>
                        {row.name}
                      </div>
                      <div className={cn(TABLE_CELL_SECONDARY, "tabular-nums")}>
                        <TickerPriceFlip
                          symbol={row.symbol}
                          detail={row.valueUsd > 0 && row.amount > 0 ? m(price(row.valueUsd / row.amount)) : undefined}
                        />
                      </div>
                    </div>
                  </div>
                </td>
                <td className={cn(TABLE_CELL_PADDING, TABLE_CELL_NUMERIC, TABLE_ROW_HOVER_BG)}>
                  {m(formatAssetAmount(row.amount, row.symbol))}
                </td>
                <td className={cn(TABLE_CELL_PADDING, TABLE_ROW_HOVER_BG)}>
                  <ValueWithPnl
                    row={row}
                    priceUsdAtClaim={basisFor(row.assetId)}
                    exact={exact}
                    showBalance={showBalance}
                  />
                </td>
                <td className={cn(TABLE_CELL_PADDING_TRAILING, "text-right", TABLE_ROW_HOVER_RIGHT)}>
                  <SwapAction assetId={row.assetId} label={t("Swap")} />
                </td>
              </tr>
            ))}
            {rows.length === 0 ? (
              <tr>
                <td colSpan={4} className="px-6 py-8 text-center text-[14px] text-muted-foreground">
                  {t("No wallet balances found.")}
                </td>
              </tr>
            ) : null}
          </tbody>
        </ScrollableTable>
      </DesktopTableSurface>
    </section>
  )
}

function PoolsBalanceSection({
  title,
  rows,
  exact,
  t,
  showBalance,
  markets,
}: {
  title: string
  rows: DashboardWalletBalanceRow[]
  exact: (usd: number) => string
  t: (key: string) => string
  showBalance: boolean
  markets?: DashboardBorrowMarkets
}) {
  const m = (value: string) => (showBalance ? value : MASK)
  return (
    <section className="min-w-0">
      <div className="mb-4">
        <h3 className="text-[18px] font-medium tracking-tight text-foreground md:text-[20px]">{title}</h3>
        <p className="mt-1 text-[13px] text-muted-foreground">{sectionCount(rows.length, "pool", "pools")}</p>
      </div>

      <DesktopTableSurface className="!rounded-none">
        <ScrollableTable layout={WALLET_POOLS_LAYOUT}>
          <thead>
            <tr className={TABLE_HEADER_ROW}>
              <th className={cn(TABLE_HEADER_CELL, "px-4", tableStickyCell("header"))}>
                <WalletMetricHeader
                  label={t("Pool")}
                  help={t("A liquidity-pool position you hold, paired tokens supplied to a DEX.")}
                />
              </th>
              <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                <WalletMetricHeader
                  label={t("LTV")}
                  help={t("The maximum loan-to-value ratio allowed against this pool as collateral.")}
                />
              </th>
              <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                <WalletMetricHeader
                  label={t("Risk Premium")}
                  help={t("An additional cost on your borrow rate based on the riskiness of your collateral")}
                />
              </th>
              <th className={cn(TABLE_HEADER_CELL, "px-4")}>
                <WalletMetricHeader label={t("Balance")} help={t("The current value of your pooled tokens.")} />
              </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-border dark:divide-white/6">
            {rows.map((row) => {
              const href = poolDetailHref(row)
              return (
                <tr key={row.id} className={`${TABLE_BODY_ROW} group`}>
                  <td className={tableStickyCell("body")}>
                    <Link href={href} className={cn("block h-full", TABLE_CELL_PADDING, "pl-6")}>
                      <PoolIdentity row={row} markets={markets} />
                    </Link>
                  </td>
                  <td className={cn(TABLE_ROW_HOVER_BG)}>
                    <Link href={href} className={cn("block h-full", TABLE_CELL_PADDING)}>
                      <PoolLtvCell row={row} mask={m} />
                    </Link>
                  </td>
                  <td className={cn(TABLE_ROW_HOVER_BG)}>
                    <Link href={href} className={cn("block h-full", TABLE_CELL_PADDING)}>
                      <PoolRiskPremiumCell row={row} markets={markets} mask={m} />
                    </Link>
                  </td>
                  <td className={cn(TABLE_ROW_HOVER_BG)}>
                    <Link href={href} className={cn("block h-full", TABLE_CELL_PADDING)}>
                      <PoolBalanceCell row={row} exact={exact} mask={m} />
                    </Link>
                  </td>
                </tr>
              )
            })}
            {rows.length === 0 ? (
              <tr>
                <td colSpan={4} className="px-6 py-8 text-center text-[14px] text-muted-foreground">
                  {t("No wallet balances found.")}
                </td>
              </tr>
            ) : null}
          </tbody>
        </ScrollableTable>
      </DesktopTableSurface>
    </section>
  )
}
