"use client"

import { ActionMetricHelp } from "@/app/components/action-page/action-metric-help"
import { useAmountDisplayPreferences } from "@/app/components/display-preferences"
import { HowItWorks } from "@/app/components/how-it-works"
import { Eye, EyeOff } from "@/app/components/icons"
import { useUmbrellaSessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { cn } from "@/lib/utils"
import { formatCompactUsd, formatPct, formatUsd } from "../format"

export function UmbrellaHero() {
  const { t } = useTranslation()
  const { showDollarAmounts, setShowDollarAmounts } = useAmountDisplayPreferences()
  const umbrella = useUmbrellaSessionContext()
  const totalStakedUsd = umbrella.marketOrder.reduce((sum, id) => sum + umbrella.positions[id].valueUsd, 0)
  const weightedApy =
    totalStakedUsd > 0
      ? umbrella.marketOrder.reduce((sum, id) => sum + umbrella.positions[id].valueUsd * umbrella.markets[id].apy, 0) /
        totalStakedUsd
      : 0
  const cooldownUsd = umbrella.marketOrder
    .filter((id) => umbrella.positions[id].cooldownStatus === "cooling")
    .reduce((sum, id) => sum + umbrella.positions[id].cooldownValueUsd, 0)
  const readyIds = umbrella.marketOrder.filter((id) => umbrella.positions[id].cooldownStatus === "ready")
  const readyUsd = readyIds.reduce((sum, id) => sum + umbrella.positions[id].cooldownValueUsd, 0)
  const readySymbols = readyIds.map((id) => umbrella.markets[id].symbol).join(", ")
  const expiredIds = umbrella.marketOrder.filter((id) => umbrella.positions[id].cooldownStatus === "expired")
  const expiredUsd = expiredIds.reduce((sum, id) => sum + umbrella.positions[id].cooldownValueUsd, 0)
  const withdrawalReadyTile = (() => {
    const hint = t(
      "Once cooldown finishes, users can unstake during the withdrawal window before cooldown has to be restarted.",
    )
    if (expiredIds.length > 0) {
      return {
        label: t("Restart cooldown"),
        hint,
        value: formatCompactUsd(expiredUsd),
        change: "",
        tone: "muted" as const,
      }
    }
    return {
      label: t("Withdrawal ready"),
      hint,
      value: formatCompactUsd(readyUsd),
      change: readySymbols,
      tone: readyUsd > 0 ? ("success" as const) : ("muted" as const),
    }
  })()
  const userUmbrellaSnapshot = [
    {
      label: t("Total position value"),
      hint: t("Includes active stake and cooldown"),
      value: formatUsd(totalStakedUsd),
      change: "",
      tone: "muted" as const,
    },
    {
      label: t("Weighted APY"),
      hint: t("Average APY across your staked positions, weighted by value."),
      value: `${formatPct(weightedApy)}%`,
      change: "",
      tone: "muted" as const,
    },
    {
      label: t("In cooldown"),
      hint: t(
        "Start cooldown before withdrawing. During cooldown, the position keeps earning incentives and remains slashable.",
      ),
      value: formatCompactUsd(cooldownUsd),
      change: "",
      tone: "warning" as const,
    },
    withdrawalReadyTile,
  ]

  return (
    <div>
      <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-2.5">
          <h2 className="text-[22px] font-medium leading-none tracking-[-0.03em] text-foreground md:text-[24px]">
            {t("Your Umbrella")}
          </h2>
          <button
            type="button"
            onClick={() => setShowDollarAmounts(!showDollarAmounts)}
            aria-label={showDollarAmounts ? t("Hide Numbers") : t("Show Numbers")}
            className="inline-flex size-8 items-center justify-center rounded-full text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
          >
            {showDollarAmounts ? <Eye className="size-[22px]" /> : <EyeOff className="size-[22px]" />}
          </button>
        </div>
        <HowItWorks topic="umbrella" />
      </div>
      {/* No `overflow-hidden` here — it would clip the tile (i) tooltips. The decorative
          dot layer carries its own rounding so it still stays within the card corners. */}
      <section className="relative rounded-radius-md bg-card px-4 py-5 dark:bg-white/[0.04] sm:px-5">
        <div className="pointer-events-none absolute inset-0 rounded-radius-md opacity-40 [background-image:radial-gradient(circle,rgba(148,163,184,0.16)_1px,transparent_1.2px)] [background-position:18px_18px] [background-size:16px_16px] dark:opacity-20 dark:[background-image:radial-gradient(circle,rgba(255,255,255,0.07)_1px,transparent_1.2px)]" />
        <div className="relative">
          <div className="grid grid-cols-2 gap-5 lg:grid-cols-4 lg:divide-x lg:divide-border">
            {userUmbrellaSnapshot.map((item) => (
              <div key={item.label} className="min-w-0 lg:px-5 first:lg:pl-0 last:lg:pr-0">
                <div className="flex items-center gap-1 text-[13px] text-muted-foreground">
                  <span>{item.label}</span>
                  {"hint" in item && item.hint ? <ActionMetricHelp text={item.hint} topic={item.label} /> : null}
                </div>
                <div className="mt-2 flex flex-wrap items-baseline gap-x-2 gap-y-1">
                  <span className="font-data text-[clamp(1.35rem,1.8vw,1.95rem)] font-medium leading-none tracking-[-0.04em] text-foreground">
                    {showDollarAmounts ? item.value : "••••"}
                  </span>
                  {showDollarAmounts && item.change ? (
                    <span
                      className={cn(
                        "text-[13px] font-semibold tabular-nums lg:text-[14px]",
                        item.tone === "warning" && "text-warning",
                        item.tone === "success" && "text-success",
                        item.tone === "muted" && "text-muted-foreground",
                      )}
                    >
                      {item.change}
                    </span>
                  ) : null}
                </div>
              </div>
            ))}
          </div>
        </div>
      </section>
    </div>
  )
}
