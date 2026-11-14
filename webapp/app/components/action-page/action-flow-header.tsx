"use client"

import Link from "next/link"
import { BrandIcon, BrandLogo } from "@/app/components/brand-logo"
import { X } from "@/app/components/icons"
import type { ActionStage } from "@/app/lib/action-system/contracts"
import { useTranslation } from "@/app/lib/i18n/use-translation"

const ACTION_FLOW_STEPS = ["Select", "Configure", "Review", "Confirm"] as const

function actionFlowStepIndex(stage: ActionStage) {
  if (stage === "select") return 0
  if (stage === "configure" || stage === "error") return 1
  if (stage === "review") return 2
  return 3
}

/** Flows without a Select stage (swap picks assets inline) count only their own steps. */
function flowSteps(hasSelectStep: boolean) {
  return hasSelectStep ? ACTION_FLOW_STEPS : ACTION_FLOW_STEPS.slice(1)
}

export function ActionFlowHeader({
  stage,
  onClose,
  mobileOnly = false,
  hasSelectStep = true,
}: {
  stage: ActionStage
  onClose: () => void
  mobileOnly?: boolean
  hasSelectStep?: boolean
}) {
  const { t } = useTranslation()
  const steps = flowSteps(hasSelectStep)
  const activeIndex = Math.max(0, actionFlowStepIndex(stage) - (hasSelectStep ? 0 : 1))
  const activeStep = steps[activeIndex]!
  const progress = ((activeIndex + 1) / steps.length) * 100
  const stepText = t("Step {current} of {total} · {label}")
    .replace("{current}", String(activeIndex + 1))
    .replace("{total}", String(steps.length))
    .replace("{label}", t(activeStep))

  return (
    <header
      className={`sticky top-0 z-40 flex h-14 items-center border-b border-border bg-background px-4 text-foreground sm:px-6 ${
        mobileOnly ? "lg:hidden" : "lg:h-14 lg:px-5 xl:px-6 2xl:px-8"
      }`}
    >
      <Link href="/" aria-label={t("Home")} title={t("Home")} className="inline-flex min-w-0 items-center">
        <BrandIcon className="xl:hidden" />
        <BrandLogo className="hidden xl:inline-flex" />
      </Link>

      <div className="pointer-events-none absolute left-1/2 w-[min(520px,calc(100%-128px))] -translate-x-1/2 text-center sm:w-[min(560px,calc(100%-192px))]">
        <div className="truncate text-[13px] font-medium leading-none text-foreground sm:text-sm">{stepText}</div>
        <div className="mx-auto mt-1.5 h-1 w-full max-w-[180px] overflow-hidden rounded-full bg-muted sm:max-w-[520px]">
          <div
            className="h-full rounded-full bg-brand transition-[width] duration-500 ease-out"
            style={{ width: `${progress}%` }}
          />
        </div>
      </div>

      <button
        type="button"
        aria-label={t("Close")}
        onClick={onClose}
        className="ml-auto inline-flex size-11 items-center justify-center rounded-full border border-brand/25 bg-brand text-white shadow-elev-1 transition-colors hover:bg-brand/90"
      >
        <X className="size-5" />
      </button>
    </header>
  )
}
