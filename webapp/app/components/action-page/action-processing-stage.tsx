"use client"

import Link from "next/link"
import { LoaderCircle } from "@/app/components/icons"
import type { ActionPreviewUi, ActionStage } from "@/app/lib/action-system/contracts"
import { ActionCard } from "@/app/components/action-page/action-metrics"
import { ActionTokenIcon } from "@/app/components/action-page/action-token-icon"
import { ProcessingNarration } from "@/app/components/action-page/processing-narration"
import { getProcessingTitle } from "@/app/lib/action-system/action-page-labels"
import { useTranslation } from "@/app/lib/i18n/use-translation"

export function ActionProcessingStage({
  verb,
  preview,
  closeHref,
  onClose,
  stage = "processing",
}: {
  verb: string
  preview: ActionPreviewUi | null
  closeHref?: string
  onClose?: () => void
  stage?: ActionStage
}) {
  const { t } = useTranslation()
  const symbol = preview?.amountLabel.split(" ").slice(-1)[0] ?? "Asset"

  return (
    <div className="space-y-4" data-testid="action-processing-stage">
      <ActionCard className="overflow-hidden">
        <div className="relative px-4 pb-2 pt-4">
          <div className="inline-flex items-center gap-2 rounded-full border border-brand/20 bg-brand-soft px-3 py-1 text-[11px] font-medium text-brand-soft-foreground">
            <LoaderCircle className="size-3.5 animate-spin" />
            {t(
              stage === "submitted"
                ? "Submitted"
                : stage === "confirmed"
                  ? "Confirmed"
                  : stage === "refreshing_position"
                    ? "Refreshing position"
                    : stage === "reconciled"
                      ? "Reconciled"
                      : "Pending",
            )}
          </div>

          <div className="flex flex-col items-center py-6 text-center">
            <ActionTokenIcon symbol={symbol} className="size-14" />
            <h2 className="mt-4 text-[1.25rem] font-medium tracking-[-0.03em]">
              {t(getProcessingTitle(verb, symbol))}
            </h2>
          </div>

          {/* The ProcessingNarration animation above already narrates each step per verb;
              a second executionSteps list here (e.g. "Confirm in wallet" / "Submit") was
              redundant across every action, so it's intentionally not rendered. */}
          <ProcessingNarration verb={verb} />
        </div>
      </ActionCard>

      {closeHref ? (
        <Link
          href={closeHref}
          className="flex h-12 w-full items-center justify-center rounded-full border border-border bg-surface-raised text-[15px] font-medium text-foreground transition-colors hover:bg-surface-hover"
        >
          {t("Close")}
        </Link>
      ) : (
        <button
          type="button"
          onClick={onClose}
          className="h-12 w-full rounded-full border border-border bg-surface-raised text-[15px] font-medium text-foreground transition-colors hover:bg-surface-hover"
        >
          {t("Close")}
        </button>
      )}
    </div>
  )
}
