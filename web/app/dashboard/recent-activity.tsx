"use client"

import * as React from "react"
import { useRouter } from "next/navigation"
import { useQuery } from "convex/react"
import { useAuthedQueryArgs } from "@/app/lib/convex/use-authed-query-args"
import { ChevronRight } from "@/app/components/icons"
import { TokenIcon } from "@/app/components/token-icon"
import { getTokenIconMeta } from "@/app/lib/token-icons"
import { api } from "@/convex/_generated/api"
import type { PortfolioActivityRow } from "@/app/lib/data/providers/portfolio"
import { formatCompactUsd } from "@/app/lib/borrow-sim"
import { useAmountDisplayPreferences } from "@/app/components/display-preferences"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { cn } from "@/lib/utils"
import {
  mapConvexActivityItemsToRows,
  mergeActivityRows,
  type ConvexActivityItem,
} from "@/app/dashboard/convex-activity"

const MASK = "••••"
const ACTIVITY_PAGE_SIZE = 10
const ACTIVITY_MAX = 200

const KIND_LABEL: Record<PortfolioActivityRow["kind"], string> = {
  swap: "Swap",
  supply: "Supply",
  withdraw: "Withdraw",
  borrow: "Borrow",
  repay: "Repay",
  pledge: "Pledge",
  claim: "Claim",
  stake: "Stake",
  startCooldown: "Cooldown",
  unstake: "Unstake",
  open: "Open",
  addCollateral: "Add collateral",
  reduce: "Reduce",
  close: "Close",
  rebalance: "Rebalance",
  interest: "Interest",
  liquidation: "Liquidation",
}

/** A candidate resolves to a real logo only when the icon registry has an image for it. */
function resolvesToLogo(symbol: string | undefined): symbol is string {
  return Boolean(symbol && getTokenIconMeta(symbol).iconUrl)
}

function firstLogoCandidate(candidates: Array<string | undefined>) {
  for (const candidate of candidates) {
    if (resolvesToLogo(candidate)) return getTokenIconMeta(candidate).symbol
  }
  return undefined
}

/**
 * Resolve the row's token symbol for the icon. Rewards → AVA. Otherwise we prefer the
 * row's real market/asset data (`marketId`, which encodes the underlying token — "gho",
 * "wsteth", "wbtc-weth-…") and only accept a candidate that maps to an actual logo, so
 * label words that are NOT tokens ("claim") can never leak through as a
 * letter-circle fallback. Ends on ETH — a real logo — so a row always shows a logo.
 */
export function inferActivityTokenSymbol(row: PortfolioActivityRow): string {
  if (row.product === "rewards") return "AVA"

  const secondary = row.secondaryLabel.replace(/\s+claimed$/i, "").trim()
  const marketId = row.marketId?.trim()
  const scopedAsset = marketId?.includes(":") ? marketId.split(":").at(-1) : undefined
  const candidates = [
    // A scoped asset id (`aero-slipstream-bluechip:usdc`) identifies the traded
    // token exactly. Checking the whole slug first used to select AERO from the
    // venue prefix, so USDC debt rows rendered with the Aerodrome logo.
    scopedAsset,
    marketId,
    ...(marketId ? marketId.split(/[-_:]/).reverse() : []),
    secondary.split(/\s+/).at(-1),
    row.primaryLabel.trim().split(/\s+/).at(-1),
  ]
  const resolved = firstLogoCandidate(candidates)
  if (resolved) return resolved
  return "ETH"
}

function activityPairFromLabel(label: string | undefined): [string, string] | null {
  if (!label?.includes("/")) return null
  const symbols = label
    .split("/")
    .map((part) => part.trim())
    .filter(Boolean)
    .map((part) => firstLogoCandidate([part]))
    .filter((symbol): symbol is string => Boolean(symbol))
  return symbols.length >= 2 ? [symbols[0]!, symbols[1]!] : null
}

/** Pool collateral activity represents an LP pair, so show both constituent token icons. */
export function inferActivityTokenSymbols(row: PortfolioActivityRow): [string, string] | null {
  const isPoolActivity =
    row.product === "pool" ||
    (row.product === "borrow" && ["withdraw", "pledge", "claim", "liquidation"].includes(row.kind))
  if (!isPoolActivity) return null

  const labeledPair = activityPairFromLabel(row.primaryLabel) ?? activityPairFromLabel(row.secondaryLabel)
  if (labeledPair) return labeledPair

  const slugParts = row.marketId?.split(/[-_:]/).filter(Boolean) ?? []
  const slugSymbols = slugParts
    .map((part) => firstLogoCandidate([part]))
    .filter((symbol): symbol is string => Boolean(symbol))
  return slugSymbols.length >= 2 ? [slugSymbols[slugSymbols.length - 2]!, slugSymbols[slugSymbols.length - 1]!] : null
}

// Amount-column sign convention: user CASH FLOW, read like a bank statement.
export const AMOUNT_SIGN_BY_KIND: Record<PortfolioActivityRow["kind"], 1 | -1 | 0> = {
  borrow: 1,
  withdraw: 1,
  claim: 1,
  unstake: 1,
  reduce: 1,
  close: 1,
  supply: -1,
  repay: -1,
  pledge: -1,
  stake: -1,
  open: -1,
  addCollateral: -1,
  liquidation: -1,
  swap: 0,
  startCooldown: 0,
  rebalance: 0,
  interest: 0,
}

function applyAmountSign(sign: 1 | -1 | 0, body: string) {
  return sign > 0 ? `+${body}` : sign < 0 ? `-${body}` : body
}

function formatRowAmount(row: PortfolioActivityRow) {
  const sign = AMOUNT_SIGN_BY_KIND[row.kind]
  const magnitude = Math.abs(row.amountUsd)
  const body = row.product === "rewards" ? `${magnitude.toLocaleString()} AVA` : formatCompactUsd(magnitude)
  return applyAmountSign(sign, body)
}

function amountToneClass(row: PortfolioActivityRow) {
  const sign = AMOUNT_SIGN_BY_KIND[row.kind]
  if (sign > 0) return "text-success"
  if (sign < 0) return "text-foreground"
  return "text-muted-foreground"
}

const REAL_TX_HASH = /^0x[0-9a-fA-F]{64}$/

function isSimulatedTxHash(txHash: string) {
  return !REAL_TX_HASH.test(txHash)
}

function getTxnHref(txHash: string) {
  return isSimulatedTxHash(txHash)
    ? `/sandbox/transactions/${encodeURIComponent(txHash)}`
    : `https://etherscan.io/tx/${txHash}`
}

function formatRelativeTime(iso: string) {
  const elapsedMs = Math.max(0, Date.now() - new Date(iso).getTime())
  const totalSeconds = Math.max(1, Math.floor(elapsedMs / 1000))

  if (totalSeconds < 60) return `${totalSeconds}s`
  const totalMinutes = Math.floor(totalSeconds / 60)
  if (totalMinutes < 60) return `${totalMinutes}m`
  const totalHours = Math.floor(totalMinutes / 60)
  if (totalHours < 24) return `${totalHours}h`
  return `${Math.floor(totalHours / 24)}d`
}

/**
 * Compact Activity feed for the dashboard sidebar (and mobile stack).
 * Seed rows cover live session actions; Convex `getActivity` paginates the
 * durable history with lazy "load more" as the user scrolls.
 */
export function RecentActivity({
  rows: seedRows,
  walletId,
}: {
  rows: PortfolioActivityRow[]
  walletId?: string | null
}) {
  const { showDollarAmounts } = useAmountDisplayPreferences()
  const { t } = useTranslation()
  const router = useRouter()
  const scrollRef = React.useRef<HTMLDivElement>(null)
  const [limit, setLimit] = React.useState(ACTIVITY_PAGE_SIZE)
  const cachedConvexRef = React.useRef<PortfolioActivityRow[]>([])

  const convexRaw = useQuery(
    api.sandbox.transactions.getActivity,
    useAuthedQueryArgs(walletId ? { wallet: walletId, limit } : null),
  )

  const convexRows = React.useMemo(() => {
    if (!convexRaw) return cachedConvexRef.current
    const mapped = mapConvexActivityItemsToRows(convexRaw as ConvexActivityItem[])
    cachedConvexRef.current = mapped
    return mapped
  }, [convexRaw])

  const isLoadingConvex = Boolean(walletId) && convexRaw === undefined && cachedConvexRef.current.length === 0
  const isLoadingMore = Boolean(walletId) && convexRaw === undefined && cachedConvexRef.current.length > 0
  const hasMore = Boolean(walletId) && limit < ACTIVITY_MAX && (convexRaw === undefined || convexRaw.length >= limit)

  const sortedRows = React.useMemo(() => mergeActivityRows(seedRows, convexRows), [convexRows, seedRows])

  const loadMore = React.useCallback(() => {
    if ((!hasMore && sortedRows.length <= limit) || isLoadingMore) return
    setLimit((current) => Math.min(current + ACTIVITY_PAGE_SIZE, ACTIVITY_MAX))
  }, [hasMore, isLoadingMore, limit, sortedRows.length])

  const amount = (row: PortfolioActivityRow) => (showDollarAmounts ? formatRowAmount(row) : MASK)

  const openReceipt = React.useCallback(
    (txHash: string) => {
      if (!txHash) return
      if (isSimulatedTxHash(txHash)) {
        router.push(getTxnHref(txHash))
      } else {
        window.open(getTxnHref(txHash), "_blank", "noopener,noreferrer")
      }
    },
    [router],
  )

  return (
    <div className="min-w-0 min-h-0">
      {isLoadingConvex && !sortedRows.length ? (
        <div className="rounded-radius-md border border-border px-4 py-8 text-center text-[13px] text-muted-foreground">
          {t("Loading")}…
        </div>
      ) : sortedRows.length ? (
        <div
          ref={scrollRef}
          className="max-h-80 overflow-y-auto overscroll-contain rounded-radius-md border border-border lg:max-h-[560px]"
          aria-label={t("Activity")}
          role="region"
          tabIndex={0}
        >
          <div className="divide-y divide-border">
            {sortedRows.slice(0, limit).map((row) => {
              const interactive = Boolean(row.txHash)
              return (
                <div
                  key={row.id}
                  {...(interactive
                    ? {
                        role: "link" as const,
                        tabIndex: 0,
                        "aria-label": `${t("View transaction")}: ${row.primaryLabel}`,
                        onClick: () => openReceipt(row.txHash),
                        onKeyDown: (event: React.KeyboardEvent) => {
                          if (event.key === "Enter" || event.key === " ") {
                            event.preventDefault()
                            openReceipt(row.txHash)
                          }
                        },
                      }
                    : {})}
                  className={cn(
                    "group flex items-center gap-3 bg-transparent px-3.5 py-3.5",
                    interactive &&
                      "cursor-pointer transition-colors hover:bg-hover focus-visible:bg-hover focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand/40",
                  )}
                >
                  {(() => {
                    const pair = inferActivityTokenSymbols(row)
                    return pair ? (
                      <span className="relative inline-flex h-8 w-12 shrink-0 items-center" aria-hidden>
                        <TokenIcon symbol={pair[0]} size="md" className="absolute left-0 top-0 z-10" />
                        <TokenIcon symbol={pair[1]} size="md" className="absolute left-4 top-0" />
                      </span>
                    ) : (
                      <TokenIcon symbol={inferActivityTokenSymbol(row)} size="md" className="shrink-0" />
                    )
                  })()}
                  <div className="min-w-0 flex-1">
                    <div className="truncate text-[14px] font-medium leading-5 tracking-[-0.02em] text-foreground">
                      {row.primaryLabel}
                    </div>
                    <div className="mt-0.5 truncate text-[12px] leading-4 text-muted-foreground">
                      {[
                        t(KIND_LABEL[row.kind]),
                        // A sub-label repeating the kind read "Claim · Claim".
                        row.secondaryLabel && row.secondaryLabel.toLowerCase() !== KIND_LABEL[row.kind].toLowerCase()
                          ? row.secondaryLabel
                          : null,
                        formatRelativeTime(row.at),
                      ]
                        .filter(Boolean)
                        .join(" · ")}
                    </div>
                  </div>
                  <div className="flex shrink-0 items-center gap-1.5">
                    <span
                      className={cn(
                        "shrink-0 font-data text-[14px] font-medium tabular-nums tracking-normal",
                        amountToneClass(row),
                      )}
                    >
                      {amount(row)}
                    </span>
                    <ChevronRight
                      className={cn(
                        "size-3.5 shrink-0 transition-opacity",
                        interactive
                          ? "text-muted-foreground opacity-0 group-hover:opacity-100 group-focus-visible:opacity-100"
                          : "invisible",
                      )}
                      aria-hidden
                    />
                  </div>
                </div>
              )
            })}
          </div>
          {/* Paged: 10 rows, then "Show more" (the feed used to scroll through every row). */}
          {hasMore || sortedRows.length > limit ? (
            <div className="border-t border-border px-3.5 py-2.5 text-center" aria-live="polite">
              <button
                type="button"
                onClick={loadMore}
                disabled={isLoadingMore}
                className="text-[13px] font-medium text-brand hover:underline disabled:text-muted-foreground disabled:no-underline"
              >
                {isLoadingMore ? `${t("Loading")}…` : t("Show more")}
              </button>
            </div>
          ) : null}
        </div>
      ) : (
        <div className="rounded-radius-md border border-border px-4 py-8 text-center text-[13px] text-muted-foreground">
          {t("No recent activity.")}
        </div>
      )}
    </div>
  )
}
