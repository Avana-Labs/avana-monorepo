"use client"

import { useCallback, useEffect, useMemo, useState } from "react"
import { useRouter } from "next/navigation"
import { useAvanaIdentity, useRewardsSessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import { useDurableRewardsClaim } from "@/app/lib/rewards-system"
import type { ActionPreviewUi, ActionStage, ActionSuccessUi } from "@/app/lib/action-system/contracts"
import { getActionDescriptor } from "@/app/lib/action-system/contracts"
import { calculateRewardSummary, evaluateAllTasksForUser } from "@/app/lib/rewards-engine"
import { mapRewardsClaimPreviewToActionUi } from "@/app/lib/action-system/adapters/rewards-preview-mapper"
import { mapBorrowSuccessToActionUi } from "@/app/lib/action-system/adapters/borrow-preview-mapper"
import { ActionPageShell } from "@/app/components/action-page/action-page-shell"
import { ActionConfigureStage } from "@/app/components/action-page/action-configure-stage"
import { ActionSuccessStage } from "@/app/components/action-page/action-success-stage"
import { ActionProcessingStage } from "@/app/components/action-page/action-processing-stage"
import { ActionReviewStage } from "@/app/components/action-page/action-review-stage"
import { formatActionUsd } from "@/app/lib/action-system/formatters"
import { runActionSubmitFlow } from "@/app/lib/action-system/action-submit-runtime"
import { dashboardHrefForProduct, successDashboardCtaLabel } from "@/app/lib/action-system/dashboard-routing"
import { isConfigureVisibleStage, isSubmittingStage, reviewStageTitle } from "@/app/lib/action-system/stage-machine"
import { actionErrorMessage } from "@/app/lib/action-system/blocked-reason"
import { useActionNetworkGuard } from "@/app/lib/web3/use-action-network-guard"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import {
  ActionSessionLoading,
  shouldShowActionSessionLoading,
} from "@/app/components/action-page/action-session-loading"

export function RewardsActionPageClient({
  closeHref = "/dashboard",
  embedded = false,
  sidebar = false,
}: {
  closeHref?: string
  embedded?: boolean
  sidebar?: boolean
}) {
  const descriptor = getActionDescriptor("rewards", "claim")
  const { t } = useTranslation()
  const router = useRouter()
  const { walletId } = useAvanaIdentity()
  const rewards = useRewardsSessionContext()
  const persistRewardsClaim = useDurableRewardsClaim()
  const networkGuard = useActionNetworkGuard()
  const [amount, setAmount] = useState("")
  const [stage, setStage] = useState<ActionStage>("configure")
  const [successUi, setSuccessUi] = useState<ActionSuccessUi | null>(null)
  const [reviewQuote, setReviewQuote] = useState<{
    preview: ActionPreviewUi
    claimUsd: number
    taskIds: string[]
  } | null>(null)
  const [outcome, setOutcome] = useState<{ tone: "error" | "success"; title: string; message: string } | null>(null)
  const [isPending, setIsPending] = useState(false)
  const claimSummary = useMemo(() => {
    const input = {
      tasks: rewards.tasks,
      wallet: walletId,
      events: rewards.state.events,
      claims: rewards.state.claims,
      now: Date.now(),
      firstLoginAt: rewards.state.firstLoginAt,
    }
    const summary = calculateRewardSummary(input)
    const progress = evaluateAllTasksForUser(input)
    return {
      claimUsd: summary.totalClaimableAmount,
      claimableTaskCount: summary.claimableTaskCount,
      taskIds: progress.filter((entry) => entry.claimableAmount > 0).map((entry) => entry.taskId),
      tokenBreakdown: progress
        .filter((entry) => entry.claimableAmount > 0)
        .map((entry) => ({
          symbol: rewards.tasks.find((item) => item.id === entry.taskId)?.rewardSymbol ?? "POINTS",
          amount: entry.claimableAmount,
        })),
    }
  }, [rewards.state.claims, rewards.state.events, rewards.state.firstLoginAt, rewards.tasks, walletId])

  useEffect(() => {
    setAmount(String(claimSummary.claimUsd || ""))
  }, [claimSummary.claimUsd])

  const previewUi: ActionPreviewUi = useMemo(() => {
    const base = mapRewardsClaimPreviewToActionUi({
      allowed: claimSummary.claimUsd > 0,
      claimUsd: claimSummary.claimUsd,
      marketLabel: t("Avana rewards"),
      claimableTaskCount: claimSummary.claimableTaskCount,
      tokenBreakdown: claimSummary.tokenBreakdown,
      blockedReason: claimSummary.claimUsd > 0 ? null : "Nothing to claim",
    })
    const blockedReason = networkGuard.blockedReason ?? base.blockedReason
    return {
      ...base,
      allowed: base.allowed && !networkGuard.blockedReason,
      blockedReason,
    }
  }, [claimSummary, networkGuard.blockedReason, t])

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
    if (stage === "configure") {
      if (!previewUi.allowed) return
      setReviewQuote({ preview: previewUi, claimUsd: claimSummary.claimUsd, taskIds: claimSummary.taskIds })
      setStage("review")
      return
    }
    if (stage !== "review") return
    if (!reviewQuote?.preview.allowed) return
    if (networkGuard.isWrongNetwork) return

    setIsPending(true)
    setOutcome(null)

    try {
      const simulated = rewards.readAdapter.mode === "sandbox"
      const claims = await runActionSubmitFlow({
        simulated,
        needsAllowance: false,
        onStage: setStage,
        execute: async () => {
          const result = await persistRewardsClaim(reviewQuote.taskIds)
          const hash = result.syntheticTxHash
          return {
            receipt: {
              status: "success" as const,
              hash,
            },
          }
        },
      })

      setSuccessUi(
        mapBorrowSuccessToActionUi({
          title: `${descriptor.primaryVerb} successful`,
          // Uses the "{amount} processed." success sink (translated via translate()),
          // matching the borrow/lend/multiply confirmation copy.
          description: `${formatActionUsd(reviewQuote.claimUsd)} processed.`,
          receiptHash: claims.receipt.hash ?? null,
          metrics: reviewQuote.preview.metrics,
          href: dashboardHrefForProduct("rewards"),
          primaryCtaLabel: successDashboardCtaLabel("rewards"),
          preview: reviewQuote.preview,
          verb: descriptor.primaryVerb,
        }),
      )
      setStage("success")
    } catch (error) {
      const rawMessage = error instanceof Error ? error.message : "Unable to claim rewards"
      // Raw backend codes stay in logs; users see plain-language copy (issue #143).
      if (process.env.NODE_ENV !== "production") console.error(rawMessage)
      setOutcome({
        tone: "error",
        title: "Something went wrong",
        message: actionErrorMessage(error, "Unable to claim rewards"),
      })
      setStage("error")
    } finally {
      setIsPending(false)
    }
  }, [
    claimSummary.claimUsd,
    claimSummary.taskIds,
    closeHref,
    descriptor.primaryVerb,
    networkGuard.isWrongNetwork,
    previewUi,
    persistRewardsClaim,
    reviewQuote,
    rewards,
    router,
    stage,
    successUi,
  ])

  if (shouldShowActionSessionLoading(rewards.hasHydratedStorage)) {
    return (
      <ActionPageShell
        mode={embedded ? "embedded" : "page"}
        density={sidebar ? "sidebar" : "default"}
        title={descriptor.title}
        subtitle={embedded ? undefined : descriptor.subtitle}
        hideTitle={embedded || sidebar}
        hideClose={embedded}
        closeHref={closeHref}
      >
        <ActionSessionLoading />
      </ActionPageShell>
    )
  }

  const hideTitle = embedded || stage === "success" || isSubmittingStage(stage) || stage === "review"

  return (
    <ActionPageShell
      mode={embedded ? "embedded" : "page"}
      density={sidebar ? "sidebar" : "default"}
      title={descriptor.title}
      subtitle={embedded ? undefined : descriptor.subtitle}
      hideTitle={hideTitle}
      hideClose={embedded}
      closeHref={closeHref}
      flowHeaderStage={!embedded ? stage : undefined}
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
          title={reviewStageTitle(descriptor.primaryVerb)}
          subtitle="Confirm the details below before signing."
          hideHeader={sidebar}
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
          amount={amount}
          onAmountChange={setAmount}
          preview={previewUi}
          assetSymbol="AVA"
          amountReadOnly
          inputLabel={sidebar ? "Claimable Rewards" : undefined}
          onPrimary={() => void handlePrimary()}
          onSecondary={handleBack}
          secondaryHref={closeHref}
          isPending={isPending}
          outcome={outcome}
          homeLayout={sidebar}
          claimSummary={sidebar}
          singlePrimaryCta={sidebar}
        />
      ) : null}
    </ActionPageShell>
  )
}
