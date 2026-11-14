"use client"

import { useEffect, useState, type ReactNode } from "react"
import { usePathname } from "next/navigation"
import { Skeleton } from "@/components/ui/skeleton"
import { cn } from "@/lib/utils"
import { detailSectionStackClass } from "@/app/components/detail-page-primitives"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { ActionWorkspaceTabs } from "@/app/components/action-page/action-workspace-tabs"
import { ActionTokenIcon } from "@/app/components/action-page/action-token-icon"
import { HOME_MODE_ITEMS } from "@/app/components/home/home-workspace-card"

/**
 * Client-gated loading skeletons — shown only while a page's client data isn't ready.
 * Deliberately NOT route-level `loading.tsx`, which flashed on every navigation;
 * `page-loading-bar.tsx` owns page-to-page transitions.
 *
 * Each skeleton's wrapper and block layout must mirror the real page so content
 * reveals in place with no shift.
 */

type BlockProps = {
  children: ReactNode
  className?: string
}

/**
 * Shared page shell. Width + padding must match the real route or the page shifts on
 * reveal; `mainClassName` lets a route override the padding to match its own main.
 */
function Page({ children, className, mainClassName }: BlockProps & { mainClassName?: string }) {
  const { t } = useTranslation()
  return (
    // A single polite status region announces the load once; the placeholder blocks inside
    // are decorative (aria-hidden) so assistive tech isn't dragged across empty rectangles.
    <div className="bg-background" role="status" aria-busy="true" aria-live="polite" aria-label={t("Loading")}>
      <span className="sr-only">{t("Loading…")}</span>
      <main className={cn("container mx-auto", mainClassName ?? "px-4 py-8")}>
        <div className={cn("mx-auto max-w-[1152px]", className)}>{children}</div>
      </main>
    </div>
  )
}

/** Mirrors the borderless product cards (`bg-card`, no border/shadow). */
function Surface({ children, className }: BlockProps) {
  return <section className={cn("rounded-radius-md border-0 bg-card shadow-none", className)}>{children}</section>
}

// home (`/`) — mirrors `HomeWorkspaceCard` + the embedded borrow action 1:1.
// NOT wrapped in `Page`: the home layout is its own shell.

/** One swap-style field box (sell / buy) — matches `SwapStyleField`. */
function HomeFieldSkeleton({ children, tone }: { children: ReactNode; tone: "raised" | "inset" }) {
  return (
    <div
      className={cn(
        "rounded-radius-xl px-4 py-3",
        tone === "raised" && "border border-border bg-field-top text-card-foreground dark:shadow-none",
        tone === "inset" && "border border-transparent bg-field-bottom",
      )}
    >
      {children}
    </div>
  )
}

export function HomeWorkspaceSkeleton() {
  const { t } = useTranslation()
  const { exact } = useCurrency()
  const zeroUsdLabel = exact(0)
  return (
    // Keep the loading testid on the root so the initial-HTML shell assertion in
    // tests/e2e/route-performance.spec.ts still finds it.
    <div
      className="bg-background"
      role="status"
      aria-busy="true"
      aria-live="polite"
      aria-label={t("Loading")}
      data-testid="home-workspace-loading"
    >
      <span className="sr-only">{t("Loading…")}</span>
      <section className="flex min-h-[calc(100dvh-4rem)] justify-center px-4 pb-12 pt-14 md:pb-16 md:pt-20">
        <div className="w-full max-w-[480px]">
          {/* Same ActionWorkspaceTabs as the real card so it reveals with zero shift.
              Non-interactive — the root status region already announces the load. */}
          <div className="pointer-events-none flex items-center justify-between gap-2" aria-hidden>
            <ActionWorkspaceTabs
              items={HOME_MODE_ITEMS.map((item) => ({ id: item.value, label: item.label }))}
              value="swap"
              onChange={() => {}}
              ariaLabel="Express actions"
              withIcons
              revealLabels
            />
          </div>

          <div className="mt-3 flex flex-col gap-2">
            <div className="flex flex-col gap-1">
              <HomeFieldSkeleton tone="raised">
                <div className="text-[15px] font-normal text-foreground/75">{t("Sell")}</div>
                <div className="mt-1.5 flex items-center justify-between gap-3 max-[360px]:flex-col max-[360px]:items-start">
                  <div className="h-[1em] min-w-0 flex-1 text-[clamp(1.5rem,4vw,2rem)] font-normal leading-none tracking-[-0.04em] text-muted-foreground/60">
                    0
                  </div>
                  {/* Mirrors the live card, whose Sell field starts on ETH. */}
                  <span className="inline-flex shrink-0 items-center gap-2 rounded-full border border-border bg-surface-raised px-3 py-1.5 text-[14px] font-normal text-foreground max-[360px]:self-end">
                    <ActionTokenIcon symbol="ETH" size="pill" />
                    ETH
                    <span aria-hidden className="text-muted-foreground">
                      ▾
                    </span>
                  </span>
                </div>
                <div className="mt-1 flex items-center justify-between gap-3 text-[14px]">
                  <span className="min-w-0 truncate text-foreground/60">{zeroUsdLabel}</span>
                </div>
              </HomeFieldSkeleton>

              <HomeFieldSkeleton tone="inset">
                <div className="text-[15px] font-normal text-foreground/75">{t("Buy")}</div>
                <div className="mt-1.5 flex items-center justify-between gap-3 max-[360px]:flex-col max-[360px]:items-start">
                  <div className="h-[1em] min-w-0 flex-1 text-[clamp(1.5rem,4vw,2rem)] font-normal leading-none tracking-[-0.04em] text-muted-foreground/60">
                    0
                  </div>
                  <span className="inline-flex shrink-0 items-center gap-2 rounded-full border border-border bg-surface-raised px-3 py-1.5 text-[14px] font-normal text-foreground max-[360px]:self-end">
                    {t("Select Asset")}
                    <span aria-hidden className="text-muted-foreground">
                      ▾
                    </span>
                  </span>
                </div>
                <div className="mt-1 flex items-center justify-between gap-3 text-[14px]">
                  <span className="min-w-0 truncate text-foreground/60">{zeroUsdLabel}</span>
                </div>
              </HomeFieldSkeleton>
            </div>

            <button
              type="button"
              disabled
              className="mt-1 inline-flex h-14 w-full items-center justify-center rounded-radius-xl bg-brand-soft text-[15px] font-normal text-brand-soft-foreground"
              data-testid="action-footer-primary"
            >
              {t("Select Asset")}
            </button>
          </div>
        </div>
      </section>
    </div>
  )
}

// Mirrors `dashboard-page-client.tsx` so the real page reveals in place. Rendered BARE
// (no Page wrapper): the route already wraps content in `main.container >
// div.max-w-[1152px]`, and double-wrapping shifts the skeleton down.
function DashboardPageSkeleton() {
  return (
    <div className={detailSectionStackClass}>
      <div className="grid lg:grid-cols-[minmax(0,1fr)_360px] lg:grid-rows-[auto_1fr] lg:gap-x-20">
        {/* Greeting row + portfolio stat cards (full-width, matches PortfolioStatCards). */}
        <div className="min-w-0 pb-8 lg:col-span-2">
          <div className="mb-5 flex items-center justify-between gap-3">
            <div className="flex min-w-0 items-center gap-2.5">
              <Skeleton className="h-7 w-44 rounded-xs md:h-8" />
              <Skeleton className="size-8 shrink-0 rounded-full" />
            </div>
            <div className="hidden gap-2 lg:flex">
              {Array.from({ length: 6 }).map((_, index) => (
                <Skeleton key={`dashboard-action-${index}`} className="size-10 rounded-full" />
              ))}
            </div>
          </div>
          <ul className="flex w-full gap-3">
            {Array.from({ length: 3 }).map((_, index) => (
              <li
                key={`dashboard-stat-${index}`}
                className="w-[min(320px,88%)] shrink-0 snap-start sm:w-[calc((100%-0.75rem)/2)] lg:w-[calc((100%-1.5rem)/3)]"
              >
                <Skeleton className="h-[176px] w-full rounded-radius-md" shimmer />
              </li>
            ))}
          </ul>
        </div>

        {/* Right sidebar: rewards cards + activity list. */}
        <aside className="min-w-0 lg:col-start-2 lg:row-start-2 lg:pt-8">
          <div className="space-y-3">
            {Array.from({ length: 2 }).map((_, index) => (
              <Surface key={`dashboard-reward-${index}`} className="p-4">
                <Skeleton className="h-3.5 w-24 rounded-xs" />
                <Skeleton className="mt-3 h-8 w-32 rounded-xs" />
              </Surface>
            ))}
          </div>
          <section className="mt-10 hidden border-t border-border pt-10 lg:block">
            <Skeleton className="mb-5 h-7 w-24 rounded-xs md:h-8" />
            <div className="space-y-3">
              {Array.from({ length: 5 }).map((_, index) => (
                <Skeleton key={`dashboard-activity-${index}`} className="h-12 w-full rounded-xs" />
              ))}
            </div>
          </section>
        </aside>

        {/* Left main: tab strip + positions table. */}
        <div className="min-w-0 lg:col-start-1 lg:row-start-2 lg:pt-8">
          <div className="mb-6 border-b border-border/90">
            <div className="flex gap-6 pb-3 sm:gap-9 sm:pb-4">
              {["w-16", "w-20", "w-16", "w-20"].map((width, index) => (
                <Skeleton key={`dashboard-tab-${index}`} className={cn("h-4 rounded-xs", width)} />
              ))}
            </div>
          </div>
          <Surface className="px-4 py-2">
            <div className="divide-y divide-border/70">
              {Array.from({ length: 5 }).map((_, index) => (
                <div key={`dashboard-row-${index}`} className="flex items-center justify-between gap-4 py-4">
                  <div className="flex min-w-0 flex-1 items-center gap-3">
                    <Skeleton className="size-9 shrink-0 rounded-full" />
                    <div className="space-y-2">
                      <Skeleton className="h-4 w-24 rounded-xs" />
                      <Skeleton className="h-3 w-16 rounded-xs" />
                    </div>
                  </div>
                  <Skeleton className="hidden h-4 w-16 rounded-xs sm:block" />
                  <Skeleton className="h-8 w-20 rounded-radius-sm" />
                </div>
              ))}
            </div>
          </Surface>
        </div>
      </div>
    </div>
  )
}

/**
 * Dashboard loading state for `dashboard-page-client.tsx`. Surfaces a retry notice after
 * ~12s so a stuck snapshot does not spin silently forever. Rendered bare (no `Page`
 * wrapper): the dashboard route already supplies `main.container > div`.
 */
export function DashboardLoading({ onRetry }: { onRetry?: () => void }) {
  const { t } = useTranslation()
  const [slow, setSlow] = useState(false)
  useEffect(() => {
    const timer = setTimeout(() => setSlow(true), 12_000)
    return () => clearTimeout(timer)
  }, [])
  return (
    <div role="status" aria-busy="true" aria-live="polite" aria-label={t("Loading")}>
      <span className="sr-only">{t("Loading dashboard…")}</span>
      {slow ? (
        <div className="mb-6 flex flex-col items-center gap-2 rounded-radius-md border border-border/60 bg-card px-4 py-5 text-center">
          <p className="text-[13px] text-muted-foreground">{t("This is taking longer than usual.")}</p>
          {onRetry ? (
            <button
              type="button"
              onClick={onRetry}
              className="text-[13px] font-normal text-foreground underline underline-offset-4 hover:no-underline"
            >
              {t("Try again")}
            </button>
          ) : null}
        </div>
      ) : null}
      <DashboardPageSkeleton />
    </div>
  )
}

// product indexes — these live at the provider/auth boundary only; there are
// deliberately no route `loading.tsx` files.

function ProductMetricStripSkeleton() {
  return (
    <div className="flex w-full items-start justify-between gap-4 pb-4">
      <div className="space-y-2">
        <Skeleton className="h-3 w-20 rounded-xs" />
        <Skeleton className="h-[18px] w-24 rounded-xs" />
      </div>
      <div className="hidden gap-8 md:flex">
        {Array.from({ length: 2 }).map((_, index) => (
          <div key={`metric-${index}`} className="space-y-2 text-right">
            <Skeleton className="ml-auto h-3 w-28 rounded-xs" />
            <Skeleton className="ml-auto h-[18px] w-16 rounded-xs" />
          </div>
        ))}
      </div>
    </div>
  )
}

function BorrowPageSkeleton() {
  return (
    <Page mainClassName="px-4 py-8">
      <div data-testid="borrow-page-skeleton">
        <ProductMetricStripSkeleton />

        <div className="mb-4 mt-[37px] space-y-3">
          <div className="flex items-center justify-between gap-3">
            <Skeleton className="h-7 w-24 rounded-xs" />
            <div className="flex items-center gap-2.5">
              <Skeleton className="hidden h-9 w-28 rounded-full md:block" />
              <Skeleton className="size-9 rounded-full" />
              <Skeleton className="size-9 rounded-full" />
            </div>
          </div>
          <div className="flex gap-3 overflow-hidden" data-testid="borrow-skeleton-carousel">
            {Array.from({ length: 4 }).map((_, index) => (
              <Surface
                key={`borrow-discovery-${index}`}
                className="h-[172px] w-[19rem] shrink-0 p-3.5 md:h-[158px] md:w-80 md:p-4"
              >
                <div className="space-y-3.5">
                  {Array.from({ length: 2 }).map((__, rowIndex) => (
                    <div key={`borrow-discovery-${index}-${rowIndex}`} className="flex items-center gap-3 px-1 py-1">
                      <div className="relative h-10 w-[52px] shrink-0">
                        <Skeleton className="absolute left-0 top-0 size-10 rounded-full" />
                        <Skeleton className="absolute left-3 top-0 size-10 rounded-full" />
                      </div>
                      <div className="min-w-0 flex-1 space-y-2">
                        <Skeleton className="h-4 w-24 rounded-xs" />
                        <Skeleton className="h-3 w-28 rounded-xs" />
                      </div>
                      <div className="space-y-2">
                        <Skeleton className="ml-auto h-4 w-14 rounded-xs" />
                        <Skeleton className="ml-auto h-3 w-12 rounded-xs" />
                      </div>
                    </div>
                  ))}
                </div>
              </Surface>
            ))}
          </div>
        </div>

        <div aria-hidden className="h-[5px]" />
        <div className="flex items-center justify-between gap-4 py-[29px]" data-testid="borrow-skeleton-filters">
          <div className="flex min-w-0 gap-2 overflow-hidden">
            {["w-14", "w-24", "w-24", "w-24", "w-24", "w-24"].map((width, index) => (
              <Skeleton key={`borrow-filter-${index}`} className={cn("h-10 shrink-0 rounded-full", width)} />
            ))}
          </div>
          <Skeleton className="h-10 w-[274px] shrink-0 rounded-full" />
        </div>

        <div className="pb-6 pt-3">
          <section className="mb-2">
            <div className="mt-4">
              <div
                className="flex items-center justify-between gap-3 py-[18px]"
                data-testid="borrow-skeleton-spoke-header"
              >
                <div className="flex gap-8">
                  <Skeleton className="h-5 w-20 rounded-xs" />
                  <Skeleton className="h-5 w-24 rounded-xs" />
                </div>
                <Skeleton className="h-7 w-40 rounded-xs" />
              </div>
              <div className="overflow-hidden bg-table-row" data-testid="borrow-skeleton-table">
                <div className="grid grid-cols-[46px_minmax(220px,1fr)_90px_150px_90px_100px_110px_190px] items-center gap-0 px-4 py-3">
                  {Array.from({ length: 8 }).map((_, index) => (
                    <Skeleton key={`borrow-heading-${index}`} className="h-3 w-14 rounded-xs" />
                  ))}
                </div>
                <div className="divide-y divide-border/70">
                  {Array.from({ length: 5 }).map((_, index) => (
                    <div key={`borrow-market-${index}`} className="flex min-h-[72px] items-center gap-4 px-4 py-3">
                      <Skeleton className="h-4 w-5 rounded-xs" />
                      <div className="flex min-w-[220px] flex-1 items-center gap-4">
                        <div className="relative h-10 w-[52px] shrink-0">
                          <Skeleton className="absolute left-0 top-0 size-10 rounded-full" />
                          <Skeleton className="absolute left-3 top-0 size-10 rounded-full" />
                        </div>
                        <div className="space-y-2">
                          <Skeleton className="h-4 w-28 rounded-xs" />
                          <Skeleton className="h-3 w-24 rounded-xs" />
                        </div>
                      </div>
                      {Array.from({ length: 5 }).map((__, metricIndex) => (
                        <Skeleton key={`borrow-market-${index}-${metricIndex}`} className="h-4 w-16 rounded-xs" />
                      ))}
                      <div className="flex gap-2">
                        <Skeleton className="h-9 w-20 rounded-radius-sm" />
                        <Skeleton className="h-9 w-20 rounded-radius-sm" />
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            </div>
          </section>
        </div>
      </div>
    </Page>
  )
}

function LendPageSkeleton() {
  return (
    <Page mainClassName="px-4 py-8">
      <div data-testid="lend-page-skeleton">
        <ProductMetricStripSkeleton />

        <section className="mt-[41px]">
          <div className="mb-5 flex items-center justify-between gap-3">
            <Skeleton className="h-7 w-24 rounded-xs" />
            <div className="flex items-center gap-2.5">
              <Skeleton className="hidden h-9 w-28 rounded-full md:block" />
              <Skeleton className="size-9 rounded-full" />
              <Skeleton className="size-9 rounded-full" />
            </div>
          </div>
          <div
            className="-mx-4 flex h-44 gap-3 overflow-hidden pl-4 sm:-mx-6 sm:pl-6"
            data-testid="lend-skeleton-carousel"
          >
            {Array.from({ length: 4 }).map((_, index) => (
              <Surface key={`lend-featured-${index}`} className="relative h-44 w-[372px] shrink-0 overflow-hidden p-6">
                <div className="flex items-start justify-between gap-3">
                  <div className="flex items-start gap-3">
                    <Skeleton className="size-16 rounded-full" />
                    <div className="space-y-2 pt-1">
                      <Skeleton className="h-4 w-28 rounded-xs" />
                      <Skeleton className="h-3 w-20 rounded-xs" />
                    </div>
                  </div>
                  <div className="space-y-2 pt-1">
                    <Skeleton className="ml-auto h-4 w-14 rounded-xs" />
                    <Skeleton className="ml-auto h-3 w-9 rounded-xs" />
                  </div>
                </div>
                <Skeleton className="absolute bottom-5 left-4 right-4 h-[58px] rounded-xs" />
              </Surface>
            ))}
          </div>
        </section>

        <section className="mt-[38px] space-y-[58px]">
          <MarketFiltersSkeleton testId="lend-skeleton-filters" searchWidth="w-[280px]" />
          <MarketGroupSkeleton testId="lend-skeleton" paired={false} columns={7} rowCount={7} />
        </section>
      </div>
    </Page>
  )
}

function MarketFiltersSkeleton({
  testId,
  searchWidth,
  padded = true,
}: {
  testId: string
  searchWidth: string
  padded?: boolean
}) {
  return (
    <div className={cn("flex items-center justify-between gap-4", padded && "py-2.5")} data-testid={testId}>
      <div className="flex min-w-0 gap-2 overflow-hidden">
        {["w-14", "w-24", "w-24", "w-24", "w-24", "w-24"].map((width, index) => (
          <Skeleton key={`${testId}-${index}`} className={cn("h-10 shrink-0 rounded-full", width)} />
        ))}
      </div>
      <Skeleton className={cn("h-10 shrink-0 rounded-full", searchWidth)} />
    </div>
  )
}

function MarketGroupSkeleton({
  testId,
  paired,
  columns,
  rowCount,
}: {
  testId: string
  paired: boolean
  columns: number
  rowCount: number
}) {
  return (
    <section className="space-y-5">
      <div className="flex min-h-[55px] items-center" data-testid={`${testId}-group-header`}>
        <Skeleton className="h-7 w-36 rounded-xs" />
      </div>
      <div className="overflow-hidden bg-table-row" data-testid={`${testId}-table`}>
        <div className="flex items-center justify-between px-6 py-3">
          {Array.from({ length: columns }).map((_, index) => (
            <Skeleton key={`${testId}-heading-${index}`} className="h-3 w-16 rounded-xs" />
          ))}
        </div>
        <div className="divide-y divide-border/70">
          {Array.from({ length: rowCount }).map((_, index) => (
            <div key={`${testId}-row-${index}`} className="flex min-h-[72px] items-center gap-4 px-6 py-3">
              <Skeleton className="h-4 w-5 rounded-xs" />
              <div className="flex min-w-[190px] flex-1 items-center gap-3">
                <div className={cn("relative shrink-0", paired ? "h-10 w-[52px]" : "size-10")}>
                  <Skeleton className="absolute left-0 top-0 size-10 rounded-full" />
                  {paired ? <Skeleton className="absolute left-3 top-0 size-10 rounded-full" /> : null}
                </div>
                <div className="space-y-2">
                  <Skeleton className="h-4 w-24 rounded-xs" />
                  <Skeleton className="h-3 w-20 rounded-xs" />
                </div>
              </div>
              {Array.from({ length: paired ? 5 : 4 }).map((__, metricIndex) => (
                <Skeleton key={`${testId}-row-${index}-${metricIndex}`} className="h-4 w-16 rounded-xs" />
              ))}
              <div className="flex gap-2">
                <Skeleton className="h-9 w-20 rounded-radius-sm" />
                <Skeleton className="h-9 w-20 rounded-radius-sm" />
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}

// market details — pair/single-token identities match each real detail route.

function DetailIdentitySkeleton({ paired }: { paired: boolean }) {
  return (
    <div className="flex items-center justify-between gap-6 border-b border-border pb-5">
      <div className="flex min-w-0 items-center gap-4">
        <div className={cn("relative shrink-0", paired ? "h-16 w-[86px]" : "size-16")}>
          <Skeleton className="absolute left-0 top-0 size-16 rounded-full" />
          {paired ? <Skeleton className="absolute left-[22px] top-0 size-16 rounded-full" /> : null}
        </div>
        <div className="space-y-2.5">
          <Skeleton className="h-6 w-48 rounded-xs" />
          <div className="flex items-center gap-3">
            <Skeleton className="h-4 w-20 rounded-xs" />
            <Skeleton className="h-4 w-28 rounded-xs" />
          </div>
        </div>
      </div>
      <div className="hidden gap-2 lg:flex">
        {Array.from({ length: 3 }).map((_, index) => (
          <Skeleton key={`detail-social-${index}`} className="size-9 rounded-full" />
        ))}
      </div>
    </div>
  )
}

function DetailActionRailSkeleton() {
  return (
    <div className="mt-6">
      <div className="grid grid-cols-2 gap-2">
        <Skeleton className="h-10 rounded-full" />
        <Skeleton className="h-10 rounded-full" />
      </div>
      <Surface className="mt-3 space-y-3 p-4">
        <Skeleton className="h-4 w-24 rounded-xs" />
        <Skeleton className="h-[112px] w-full rounded-radius-md" />
        <div className="grid grid-cols-2 gap-3">
          <Skeleton className="h-14 rounded-radius-md" />
          <Skeleton className="h-14 rounded-radius-md" />
        </div>
        <Skeleton className="h-14 w-full rounded-radius-md" />
      </Surface>
    </div>
  )
}

function DetailPageSkeleton({ testId, paired }: { testId: string; paired: boolean }) {
  return (
    <Page mainClassName="px-4 pb-24 pt-12 md:pb-12 md:pt-14">
      <div data-testid={testId}>
        <div className="mb-4 flex items-center gap-2">
          <Skeleton className="h-4 w-16 rounded-xs" />
          <Skeleton className="h-4 w-28 rounded-xs" />
        </div>
        <div className="grid lg:grid-cols-[minmax(0,1fr)_360px] lg:grid-rows-[auto_1fr] lg:gap-x-20">
          <div className="min-w-0 lg:col-span-2">
            <DetailIdentitySkeleton paired={paired} />
          </div>
          <div className="min-w-0 lg:col-start-1 lg:row-start-2">
            <section className="mb-12 pt-9">
              <Skeleton className="h-8 w-36 rounded-xs" />
              <Skeleton className="mt-5 h-[260px] w-full rounded-xs" shimmer />
              <div className="mt-4 flex gap-5">
                {Array.from({ length: 6 }).map((_, index) => (
                  <Skeleton key={`detail-range-${index}`} className="h-4 w-8 rounded-xs" />
                ))}
              </div>
              <div className="mt-5 flex gap-5 border-t border-border pt-4">
                {Array.from({ length: 4 }).map((_, index) => (
                  <Skeleton key={`detail-metric-tab-${index}`} className="h-4 w-20 rounded-xs" />
                ))}
              </div>
            </section>
            <section className="space-y-10">
              <div className="space-y-3">
                <Skeleton className="h-7 w-44 rounded-xs" />
                <Skeleton className="h-4 w-full rounded-xs" />
                <Skeleton className="h-4 w-11/12 rounded-xs" />
                <Skeleton className="h-4 w-4/5 rounded-xs" />
              </div>
              <div className="space-y-6">
                <Skeleton className="h-7 w-36 rounded-xs" />
                <div className="grid grid-cols-2 gap-x-6 gap-y-6 sm:grid-cols-3">
                  {Array.from({ length: 6 }).map((_, index) => (
                    <div key={`detail-stat-${index}`} className="space-y-2">
                      <Skeleton className="h-3 w-24 rounded-xs" />
                      <Skeleton className="h-5 w-20 rounded-xs" />
                    </div>
                  ))}
                </div>
              </div>
              <Surface className="h-[280px] w-full p-5">
                <Skeleton className="h-7 w-40 rounded-xs" />
                <Skeleton className="mt-6 h-[190px] w-full rounded-xs" />
              </Surface>
            </section>
          </div>
          <aside className="hidden lg:col-start-2 lg:row-start-2 lg:block lg:self-start">
            <DetailActionRailSkeleton />
          </aside>
        </div>
      </div>
    </Page>
  )
}

function BorrowPoolDetailSkeleton() {
  return <DetailPageSkeleton testId="borrow-pool-detail-skeleton" paired />
}

function BorrowAssetDetailSkeleton() {
  return <DetailPageSkeleton testId="borrow-asset-detail-skeleton" paired={false} />
}

function LendMarketDetailSkeleton() {
  return <DetailPageSkeleton testId="lend-market-detail-skeleton" paired={false} />
}

/**
 * Route-aware content skeleton, rendered BELOW the persistent site header (which sits
 * above the session/auth gates) so a skeleton never swaps the whole page. Falls back to
 * the neutral product skeleton for routes without a bespoke one.
 */
export function RouteContentSkeleton() {
  const pathname = usePathname()
  if (
    pathname === "/ask" ||
    pathname.startsWith("/ask/") ||
    pathname === "/actions" ||
    pathname.startsWith("/actions/")
  ) {
    // Ask and action pages own their init states; the generic skeleton would flash a
    // large unrelated placeholder before their focused shells mount.
    return <div data-testid="focused-route-pending" className="min-h-[100dvh] bg-background" aria-hidden />
  }
  if (pathname.startsWith("/borrow/markets/") || pathname.startsWith("/borrow/pool/")) {
    return <BorrowPoolDetailSkeleton />
  }
  if (pathname.startsWith("/borrow/assets/") || pathname.startsWith("/borrow/asset/")) {
    return <BorrowAssetDetailSkeleton />
  }
  if (pathname.startsWith("/lend/markets/")) return <LendMarketDetailSkeleton />
  if (pathname === "/borrow") return <BorrowPageSkeleton />
  if (pathname === "/lend") return <LendPageSkeleton />
  if (pathname === "/") return <HomeWorkspaceSkeleton />
  if (pathname === "/dashboard" || pathname.startsWith("/dashboard/")) {
    // Must match the dashboard route's own wrapper so the route skeleton, the client's
    // skeleton and the real content all paint at the identical position.
    return (
      <Page mainClassName="px-3 py-6 sm:px-4 md:py-10">
        <DashboardPageSkeleton />
      </Page>
    )
  }
  if (pathname === "/rewards" || pathname.startsWith("/rewards/")) return <RewardsPageSkeleton />
  return <ProductRoutePending />
}

// rewards (`/rewards`) — shown by the rewards client while storage/snapshot load.

function RewardsPageSkeleton() {
  return (
    <Page mainClassName="px-3 py-6 sm:px-4 md:py-10">
      <div className="mb-12">
        <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
          <Skeleton className="h-7 w-40 rounded-xs md:h-8" />
          <Skeleton className="h-8 w-28 rounded-full" />
        </div>
        {/* Balance hero (left) + promo card (right, md+) — RewardsBalanceHero. */}
        <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_360px] lg:items-start lg:gap-x-20">
          <Surface className="relative min-h-[310px] px-4 py-4 sm:px-5">
            <div className="space-y-3">
              <Skeleton className="h-8 w-36 rounded-xs" />
              <Skeleton className="h-4 w-28 rounded-xs" />
            </div>
            <Skeleton className="mt-10 h-[210px] w-full rounded-xs" />
          </Surface>

          <div className="hidden space-y-3 lg:block">
            <Surface className="p-4">
              <Skeleton className="mb-3 h-3.5 w-28 rounded-xs" />
              <Skeleton className="h-8 w-36 rounded-xs" />
            </Surface>
            <Surface className="p-4">
              <Skeleton className="mb-3 h-3.5 w-28 rounded-xs" />
              <Skeleton className="h-8 w-36 rounded-xs" />
            </Surface>
          </div>
        </div>
      </div>

      <div className="space-y-14 md:space-y-16">
        <section>
          <div className="mb-6">
            <Skeleton className="h-7 w-48 rounded-xs md:h-8" />
          </div>
          {/* Underline tab strip (left-aligned, border-b). */}
          <div className="mb-6 border-b border-border/90">
            <div className="flex gap-6 pb-3 sm:gap-9 sm:pb-4">
              {["w-20", "w-24", "w-20"].map((width, index) => (
                <Skeleton key={`rewards-tab-${index}`} className={cn("h-4 rounded-xs", width)} />
              ))}
            </div>
          </div>

          {/* Quest grid — QuestsTab: h-full cards with icon + badge, title block, and a
              bottom CTA, laid out 1 → 2 → 4 → 5 columns. */}
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4 2xl:grid-cols-5">
            {Array.from({ length: 8 }).map((_, index) => (
              <Surface key={`rewards-quest-${index}`} className="flex h-full flex-col p-3.5">
                <div className="flex items-start justify-between gap-3">
                  <Skeleton className="h-9 w-9 rounded-radius-md" />
                  <Skeleton className="h-4 w-16 rounded-full" />
                </div>
                <div className="mt-3 space-y-2 sm:mt-3.5">
                  <Skeleton className="h-3.5 w-full rounded-xs" />
                  <Skeleton className="h-3.5 w-4/5 rounded-xs" />
                  <Skeleton className="h-3 w-2/3 rounded-xs" />
                  <Skeleton className="h-3.5 w-20 rounded-xs" />
                </div>
                <div className="mt-auto pt-3.5">
                  <Skeleton className="h-9 w-full rounded-radius-sm" />
                </div>
              </Surface>
            ))}
          </div>
        </section>
      </div>
    </Page>
  )
}

/**
 * Layout-stable product chrome while session/auth chunks attach. Suspense / dynamic()
 * fallback only — route `loading.tsx` still flashes on every soft navigation.
 */
function ProductRoutePending() {
  return (
    <Page>
      <div data-testid="product-route-pending" className="space-y-8">
        <div className="space-y-3">
          <Skeleton className="h-8 w-48 rounded-xs" />
          <Skeleton className="h-4 w-72 max-w-full rounded-xs" />
        </div>
        <div className="grid gap-4 sm:grid-cols-3">
          <Surface className="p-4">
            <Skeleton className="mb-3 h-3.5 w-24 rounded-xs" />
            <Skeleton className="h-8 w-32 rounded-xs" />
          </Surface>
          <Surface className="p-4">
            <Skeleton className="mb-3 h-3.5 w-24 rounded-xs" />
            <Skeleton className="h-8 w-32 rounded-xs" />
          </Surface>
          <Surface className="p-4">
            <Skeleton className="mb-3 h-3.5 w-24 rounded-xs" />
            <Skeleton className="h-8 w-32 rounded-xs" />
          </Surface>
        </div>
        <Surface className="p-4">
          <Skeleton className="mb-4 h-4 w-40 rounded-xs" />
          <div className="space-y-3">
            {Array.from({ length: 6 }).map((_, index) => (
              <Skeleton key={`product-row-${index}`} className="h-12 w-full rounded-xs" />
            ))}
          </div>
        </Surface>
      </div>
    </Page>
  )
}
