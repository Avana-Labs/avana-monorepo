"use client"

import { useSearchParams } from "next/navigation"
import { Suspense, useState } from "react"
import { ActionIcon } from "@/app/components/action-icon"
import { primaryCtaClass, secondaryCtaClass } from "@/app/components/action-page/action-cta"
import { detailSectionStackClass, MobileDetailActionBar } from "@/app/components/detail-page-primitives"
import { useUmbrellaSessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import { UmbrellaPageSkeleton } from "@/app/components/loading-states"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import type { UmbrellaMarketId } from "@/app/lib/umbrella-system/use-umbrella-session"
import { cn } from "@/lib/utils"
import { UmbrellaCooldown } from "./_detail/market-sections/UmbrellaCooldown"
import { UmbrellaHero } from "./_detail/market-sections/UmbrellaHero"
import { UmbrellaLearn } from "./_detail/market-sections/UmbrellaLearn"
import { UmbrellaPositions } from "./_detail/market-sections/UmbrellaPositions"
import { UmbrellaStress, UmbrellaSurfaceDetails } from "./_detail/market-sections/UmbrellaStress"
import { UmbrellaMobileSidebarSheet, type UmbrellaMobileSheetTrigger } from "./_detail/UmbrellaMobileSidebarSheet"
import { UmbrellaSidebar } from "./_detail/sidebars/UmbrellaSidebar"

const VALID_MARKETS: readonly UmbrellaMarketId[] = ["gho", "usdc", "usdt", "weth"]

function isUmbrellaMarketId(value: string | null): value is UmbrellaMarketId {
  return value != null && (VALID_MARKETS as readonly string[]).includes(value)
}

function defaultUmbrellaMarket(
  umbrella: ReturnType<typeof useUmbrellaSessionContext>,
  marketParam: string | null,
): UmbrellaMarketId {
  if (isUmbrellaMarketId(marketParam)) return marketParam
  const withValue = umbrella.marketOrder
    .map((id) => ({ id, value: umbrella.positions[id]?.valueUsd ?? 0 }))
    .sort((a, b) => b.value - a.value)
  if (withValue.length > 0 && withValue[0].value > 0) return withValue[0].id
  return "usdc"
}

function UmbrellaPageInner() {
  const { t } = useTranslation()
  const searchParams = useSearchParams()
  const umbrella = useUmbrellaSessionContext()
  const marketParam = searchParams.get("market")
  // Fallback: if the URL didn't pick a market, choose the one this wallet actually holds
  // most of. Empty state → "usdc". Lazy state initializer runs once on mount so the
  // seed doesn't fight later user selections when positions refresh.
  const initialMarket = defaultUmbrellaMarket(umbrella, marketParam)
  const [selectedMarket, setSelectedMarket] = useState<UmbrellaMarketId>(initialMarket)
  const [selectedSurfaceMarket, setSelectedSurfaceMarket] = useState<UmbrellaMarketId>("gho")
  const [mobileSheetOpen, setMobileSheetOpen] = useState(false)
  const [mobileSheetInitialTab, setMobileSheetInitialTab] = useState<UmbrellaMobileSheetTrigger>("stake")

  const openSheet = (tab: UmbrellaMobileSheetTrigger) => {
    setMobileSheetInitialTab(tab)
    setMobileSheetOpen(true)
  }

  return (
    <div className="bg-background">
      <main className="container mx-auto px-3 py-6 pb-28 sm:px-4 md:py-10 lg:pb-10">
        <h1 className="sr-only">{t("Umbrella")}</h1>
        <div className="mx-auto max-w-[1152px]">
          <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_360px] lg:items-start lg:gap-x-20">
            <div className={cn(detailSectionStackClass, "min-w-0")}>
              {/* Hero + positions share one block so no divider falls between them;
                  the cooldown queue follows immediately after positions. */}
              <div className="space-y-10">
                <UmbrellaHero />
                <UmbrellaPositions onSelectMarket={setSelectedMarket} />
              </div>
              <UmbrellaCooldown />
              <UmbrellaStress />
              <UmbrellaSurfaceDetails marketId={selectedSurfaceMarket} onMarketChange={setSelectedSurfaceMarket} />
              <UmbrellaLearn />
            </div>

            <aside className="hidden lg:block lg:self-start" aria-label={t("Umbrella actions")}>
              <div className="sticky top-20 space-y-8">
                <UmbrellaSidebar moduleId={selectedMarket} onMarketChange={setSelectedMarket} />
              </div>
            </aside>
          </div>

          <MobileDetailActionBar className="grid grid-cols-2 gap-3">
            <button
              type="button"
              onClick={() => openSheet("unstake")}
              aria-label={t("Unstake from umbrella")}
              className={secondaryCtaClass({ size: "compact", className: "gap-2.5 font-bold [&_svg]:size-5" })}
            >
              <ActionIcon label={t("Unstake")} />
              {t("Unstake")}
            </button>
            <button
              type="button"
              onClick={() => openSheet("stake")}
              aria-label={t("Stake in umbrella")}
              className={primaryCtaClass({ size: "compact", className: "gap-2.5 font-bold [&_svg]:size-5" })}
            >
              <ActionIcon label={t("Stake")} />
              {t("Stake")}
            </button>
          </MobileDetailActionBar>

          <UmbrellaMobileSidebarSheet
            open={mobileSheetOpen}
            onOpenChange={setMobileSheetOpen}
            moduleId={selectedMarket}
            onMarketChange={setSelectedMarket}
            initialTab={mobileSheetInitialTab}
          />
        </div>
      </main>
    </div>
  )
}

/**
 * Single hydration gate (mirrors the dashboard): show ONE layout-matched skeleton
 * until the umbrella session's own Convex data is ready, then render the real page
 * in one pass. No per-tile `$0` placeholder flash, and mounting `UmbrellaPageInner`
 * only after hydration lets its default-market seed read the real positions.
 */
function UmbrellaPageGate() {
  const umbrella = useUmbrellaSessionContext()
  if (!umbrella.isHydrated) return <UmbrellaPageSkeleton />
  return <UmbrellaPageInner />
}

export default function UmbrellaPage() {
  // useSearchParams() requires a Suspense boundary so the page can be statically
  // prerendered (Next.js CSR bailout); without it the production/static-export
  // build fails to prerender /umbrella.
  return (
    <Suspense fallback={<UmbrellaPageSkeleton />}>
      <UmbrellaPageGate />
    </Suspense>
  )
}
