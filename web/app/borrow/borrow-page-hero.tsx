"use client"

import { useMemo } from "react"
import { CarouselArrowButtons, useOverflowCarousel } from "@/app/components/carousel-arrow-buttons"
import { HowItWorks } from "@/app/components/how-it-works"
import type { BorrowPageData } from "@/app/lib/data/providers/borrow"
import { borrowMarketDetailPath } from "@/app/lib/borrow-routes"
import { formatBorrowPairLabel, formatLtvPct } from "@/app/lib/borrow-market-rows"
import { formatApy } from "@/app/lib/format"
import { MOBILE_EDGE_RAIL_CLASS } from "@/app/lib/ui/horizontal-rail"
import { cn } from "@/lib/utils"
import { HeroMarketCard } from "./borrow-hero-market-card"
import { BorrowHeroLiveMetrics } from "./borrow-hero-live-metrics"

type ExplorePool = BorrowPageData["poolCatalog"][number]

const averageApr = (pool: ExplorePool) => (pool.aprMin + pool.aprMax) / 2

function buildHeroCards(pageData: BorrowPageData) {
  // Draw each card's two markets from the FULL pool catalog (re-sorted per ranking)
  // rather than the pre-sliced 3-item explore lists. Extra cards are filled from
  // leftover pools so the desktop carousel has enough unique markets to scroll.
  const catalog = pageData.poolCatalog
  const byTvl = [...catalog].sort((a, b) => b.tvlUsd - a.tvlUsd)

  const used = new Set<string>()
  const take = (pool: ExplorePool | null | undefined): ExplorePool | null => {
    if (!pool || used.has(pool.name)) return null
    used.add(pool.name)
    return pool
  }
  const norm = (s: string) => s.toUpperCase()
  // Resolve a curated pick by its two token symbols, preferring the named venue but
  // falling back to any spoke so it still resolves if the pool lives on a different one.
  const findPool = (spoke: string, a: string, b: string): ExplorePool | null => {
    const matches = (p: ExplorePool) => {
      const syms = p.visuals.map((v) => norm(v.symbol))
      return syms.includes(norm(a)) && syms.includes(norm(b))
    }
    return catalog.find((p) => p.spoke === spoke && matches(p)) ?? catalog.find(matches) ?? null
  }

  const toRows = (pools: ReadonlyArray<ExplorePool>, prefix: string) =>
    pools.map((pool) => ({
      id: `${prefix}-${pool.id}`,
      href: borrowMarketDetailPath(pool.id),
      pool,
      title: formatBorrowPairLabel(pool),
      // LTV is the headline (more important than availability); the line below is the
      // pool's own trading-fee APR — "LP APR", the name the table and detail page use.
      value: `${formatLtvPct(pool.ltv)} LTV`,
      delta: `${formatApy(averageApr(pool))} LP APR`,
      deltaClassName: "text-apy-positive",
    }))

  // Hand-curated Explore carousel: these exact markets, in this order, two per card.
  // Each entry is [preferred venue spoke, tokenA, tokenB]; findPool falls back to any
  // spoke. Card 5 auto-fills from the highest-TVL pools not already featured.
  const CURATED_CARDS: ReadonlyArray<ReadonlyArray<readonly [string, string, string]>> = [
    [
      ["bal-stable", "GHO", "USDC"],
      ["uni-v3-bluechip", "WBTC", "USDC"],
    ],
    [
      ["aero-concentrated-stocks", "USDC", "GOOGLc"],
      ["uni-v3-bluechip", "WETH", "USDC"],
    ],
    [
      ["uni-robinhood-stocks", "TSLA", "USDG"],
      ["aero-concentrated-stocks", "USDC", "AAPLc"],
    ],
    [
      ["uni-v3-bluechip", "cbBTC", "WETH"],
      ["uni-v3-stable", "crvUSD", "USDC"],
    ],
  ]

  const cards = CURATED_CARDS.map((pairs, ci) => {
    const rows = pairs.map(([spoke, a, b]) => take(findPool(spoke, a, b))).filter((p): p is ExplorePool => p !== null)
    return { id: `curated-${ci}`, rows: toRows(rows, `curated-${ci}`) }
  }).filter((card) => card.rows.length > 0)

  // Cap the carousel at 5 cards; fill any remaining with top-TVL leftovers.
  let extra = 0
  while (cards.length < 5) {
    const next: ExplorePool[] = []
    for (const pool of byTvl) {
      if (next.length === 2) break
      const chosen = take(pool)
      if (chosen) next.push(chosen)
    }
    if (next.length < 2) break
    cards.push({ id: `more-${extra}`, rows: toRows(next, `more-${extra}`) })
    extra += 1
  }

  return cards
}

export function BorrowPageHero({ pageData }: { pageData: BorrowPageData }) {
  // Memoize so the hero cards keep a stable identity across re-renders; rebuilding
  // them every render churned the scroller's children and reflowed it (a flicker)
  // whenever live data swapped in or any parent re-rendered.
  const heroCards = useMemo(() => buildHeroCards(pageData), [pageData])
  const { scrollerRef, canPrev, canNext, scrollByCard } = useOverflowCarousel({ dragToScroll: true })

  return (
    <section className="mb-4">
      <BorrowHeroLiveMetrics metrics={pageData.heroMetrics} />

      <div className="mt-6 space-y-3">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <h2 className="mt-1 text-[22px] font-medium tracking-[-0.03em] text-foreground md:text-[24px]">Explore</h2>
          <div className="flex items-center gap-2.5">
            <HowItWorks topic="borrow" className="hidden md:inline-flex" />
            <CarouselArrowButtons
              canPrev={canPrev}
              canNext={canNext}
              onPrev={() => scrollByCard(-1)}
              onNext={() => scrollByCard(1)}
              prevLabel="Previous explore"
              nextLabel="Next explore"
            />
          </div>
        </div>

        <div
          ref={scrollerRef}
          className={cn(
            "overflow-x-auto scroll-smooth pb-1 [scrollbar-width:none] snap-x snap-mandatory [&::-webkit-scrollbar]:hidden",
            MOBILE_EDGE_RAIL_CLASS,
          )}
        >
          <div className="flex min-w-max gap-3">
            {heroCards.map((card, index) => (
              <HeroMarketCard key={card.id} rows={card.rows} className="snap-start" eagerFirstRow={index === 0} />
            ))}
          </div>
        </div>
      </div>
    </section>
  )
}
