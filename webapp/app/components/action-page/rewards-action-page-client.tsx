"use client"

import { useCallback, useMemo, useState } from "react"
import { useRouter } from "next/navigation"
import { useAvanaSessions } from "@/app/lib/avana-session/avana-sessions-provider"
import type { ActionPreviewUi, ActionStage, ActionSuccessUi } from "@/app/lib/action-system/contracts"
import { getActionDescriptor } from "@/app/lib/action-system/contracts"
import { mapRewardsRedeemPreviewToActionUi } from "@/app/lib/action-system/adapters/rewards-preview-mapper"
import { mapBorrowSuccessToActionUi } from "@/app/lib/action-system/adapters/borrow-preview-mapper"
import { ActionPageShell } from "@/app/components/action-page/action-page-shell"
import { ActionConfigureStage } from "@/app/components/action-page/action-configure-stage"
import { ActionSuccessStage } from "@/app/components/action-page/action-success-stage"
import { ActionProcessingStage } from "@/app/components/action-page/action-processing-stage"
import { ActionReviewStage } from "@/app/components/action-page/action-review-stage"
import { runActionSubmitFlow } from "@/app/lib/action-system/action-submit-runtime"
import { dashboardHrefForProduct, successDashboardCtaLabel } from "@/app/lib/action-system/dashboard-routing"
import { isConfigureVisibleStage, isSubmittingStage } from "@/app/lib/action-system/stage-machine"
import { maxRedeemSteps, redeemPoints } from "@/app/lib/rewards/redeem-points"
import { useWalletRewards } from "@/app/lib/rewards/use-wallet-rewards"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { ActionSessionLoading } from "@/app/components/action-page/action-session-loading"

const DAY_MS = 86_400_000

/**
 * The page where points are spent on the temporary fee discount (`/actions/rewards/claim`), on the same stages as every
 * other action: configure, review, processing and the receipt. It redeems as many steps as the wallet's points and the
 * cap on what it may hold at once allow; Convex checks both again.
 */
export function RewardsActionPageClient({ closeHref = "/dashboard" }: { closeHref?: string }) {
  const descriptor = getActionDescriptor("rewards", "claim")
  const { t, language } = useTranslation()
  const router = useRouter()
  const { walletId } = useAvanaSessions()
  const rewards = useWalletRewards(walletId)
  const [stage, setStage] = useState<ActionStage>("configure")
  const [successUi, setSuccessUi] = useState<ActionSuccessUi | null>(null)
  const [reviewQuote, setReviewQuote] = useState<{ preview: ActionPreviewUi; steps: number } | null>(null)
  const [outcome, setOutcome] = useState<{ tone: "error" | "success"; title: string; message: string } | null>(null)
  const [isPending, setIsPending] = useState(false)

  const quote = useMemo(() => {
    if (!rewards) return null
    const { redemption: rules, availablePoints } = rewards
    const heldBps = rewards.activeRedemptions.reduce((sum, r) => sum + r.bps, 0)
    const steps = maxRedeemSteps(availablePoints, heldBps, rules)
    // A wallet that cannot redeem still sees what one step would buy.
    const shown = Math.max(1, steps)
    const points = shown * rules.pointsPerStep
    const bps = shown * rules.bpsPerStep
    const endsAt = Date.now() + rules.days * DAY_MS
    return {
      steps,
      points,
      bps,
      endsAt,
      pointsLeft: availablePoints - steps * rules.pointsPerStep,
      availablePoints,
      rules,
    }
  }, [rewards])

  const formatPoints = useCallback((n: number) => t("{points} pts").replace("{points}", n.toLocaleString("en-US")), [t])
  const formatBps = useCallback((n: number) => t("{bps} bps off").replace("{bps}", String(n)), [t])
  const formatDate = useCallback(
    (ms: number) => new Date(ms).toLocaleDateString(language === "EN" ? undefined : language.toLowerCase()),
    [language],
  )

  const previewUi: ActionPreviewUi | null = useMemo(() => {
    if (!quote) return null
    return mapRewardsRedeemPreviewToActionUi({
      allowed: quote.steps > 0,
      points: quote.points,
      labels: {
        points: formatPoints(quote.availablePoints),
        discount: formatBps(quote.bps),
        validUntil: formatDate(quote.endsAt),
        pointsLeft: formatPoints(quote.pointsLeft),
      },
      blockedReason:
        quote.availablePoints < quote.rules.pointsPerStep
          ? "Not enough points to redeem."
          : "You already hold the largest discount allowed.",
    })
  }, [quote, formatPoints, formatBps, formatDate])

  const handleBack = useCallback(() => {
    if (stage === "review") {
      setStage("configure")
      setReviewQuote(null)
      setOutcome(null)
      return
    }
    router.push(closeHref)
  }, [closeHref, router, stage])

  const handlePrimary = useCallback(async () => {
    if (stage === "success") {
      router.push(successUi?.primaryCtaHref ?? dashboardHrefForProduct("rewards"))
      return
    }
    if (!quote || !previewUi) return
    if (stage === "configure") {
      if (!previewUi.allowed) return
      setReviewQuote({ preview: previewUi, steps: quote.steps })
      setStage("review")
      return
    }
    if (stage !== "review" || !reviewQuote?.preview.allowed) return

    setIsPending(true)
    setOutcome(null)
    try {
      const done = await runActionSubmitFlow({
        // A redemption moves nothing on chain: no wallet signature, so none of the simulated pacing.
        simulated: false,
        onStage: setStage,
        execute: async () => {
          const result = await redeemPoints(reviewQuote.steps)
          if (!result.ok) throw new Error("redeem failed")
          return { receipt: { status: "success" as const, hash: null }, result }
        },
      })
      setSuccessUi(
        mapBorrowSuccessToActionUi({
          title: `${descriptor.primaryVerb} successful`,
          description: t("{bps} bps off until {date}")
            .replace("{bps}", String(done.result.bps))
            .replace("{date}", formatDate(done.result.endsAt)),
          receiptHash: null,
          metrics: reviewQuote.preview.metrics,
          href: dashboardHrefForProduct("rewards"),
          primaryCtaLabel: successDashboardCtaLabel("rewards"),
          preview: reviewQuote.preview,
          verb: descriptor.primaryVerb,
        }),
      )
      setStage("success")
    } catch {
      setOutcome({ tone: "error", title: "Something went wrong", message: "Could not redeem. Try again." })
      setStage("error")
    } finally {
      setIsPending(false)
    }
  }, [descriptor.primaryVerb, formatDate, previewUi, quote, reviewQuote, router, stage, successUi, t])

  if (!quote || !previewUi) {
    return (
      <ActionPageShell title={descriptor.title} subtitle={descriptor.subtitle} closeHref={closeHref}>
        <ActionSessionLoading />
      </ActionPageShell>
    )
  }

  const hideTitle = stage === "success" || isSubmittingStage(stage) || stage === "review"

  return (
    <ActionPageShell
      title={descriptor.title}
      subtitle={descriptor.subtitle}
      hideTitle={hideTitle}
      closeHref={closeHref}
      flowHeaderStage={stage}
    >
      {isSubmittingStage(stage) ? (
        <ActionProcessingStage
          verb={descriptor.primaryVerb}
          preview={reviewQuote?.preview ?? previewUi}
          closeHref={closeHref}
          stage={stage}
        />
      ) : null}

      {stage === "review" ? (
        <ActionReviewStage
          title="Review redemption"
          subtitle="Review and confirm your redemption."
          preview={reviewQuote?.preview ?? previewUi}
          primaryLabel={descriptor.primaryVerb}
          onPrimary={() => void handlePrimary()}
          onSecondary={handleBack}
        />
      ) : null}

      {stage === "success" && successUi ? <ActionSuccessStage success={successUi} closeHref={closeHref} /> : null}

      {isConfigureVisibleStage(stage) ? (
        <ActionConfigureStage
          stage={stage === "error" ? "configure" : stage}
          verb={descriptor.primaryVerb}
          amount={String(quote.points)}
          onAmountChange={() => undefined}
          preview={previewUi}
          assetSymbol="PTS"
          amountReadOnly
          onPrimary={() => void handlePrimary()}
          onSecondary={handleBack}
          secondaryHref={closeHref}
          isPending={isPending}
          outcome={outcome}
        />
      ) : null}
    </ActionPageShell>
  )
}
