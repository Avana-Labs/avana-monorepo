import type { ActionStage } from "./contracts"
import { blockedCtaLabel } from "./blocked-ui"

export function isConfigureVisibleStage(stage: ActionStage) {
  return stage === "configure" || stage === "error"
}

export function isProcessingStage(stage: ActionStage) {
  return ["processing", "submitted", "confirmed", "refreshing_position", "reconciled"].includes(stage)
}

/**
 * Post-review stages where the pending view owns the screen and the editable amount card must NOT
 * re-render. Kept distinct from `isProcessingStage` so CTA labels stay signature-specific while
 * the wallet is signing.
 */
export function isSubmittingStage(stage: ActionStage) {
  return stage === "approve_allowance" || stage === "wallet_sign" || isProcessingStage(stage)
}

export function secondaryCtaLabel(stage: ActionStage, options?: { canGoBack?: boolean }) {
  if (stage === "success") return "Done"
  if (stage === "review") return "Back"
  if (stage === "configure" && options?.canGoBack) return "Back"
  return "Cancel"
}

export function primaryCtaLabel(options: {
  stage: ActionStage
  verb: string
  blockedReason: string | null
  isValid: boolean
  amountEntered?: boolean
  /** Asset spent by the action, used for "Insufficient {SYMBOL}" labels. */
  blockedSymbol?: string
}) {
  if (options.stage === "success") return "View dashboard"
  if (isProcessingStage(options.stage)) return "Processing…"
  if (options.stage === "wallet_sign" || options.stage === "approve_allowance") return options.verb
  if (options.stage === "error") return options.verb
  if (options.stage === "review") return options.verb
  // The button IS the gate: a blocked action shows a short reason in-place
  // instead of a pop-up. See blockedCtaLabel for the full mapping.
  if (options.blockedReason) return blockedCtaLabel(options.blockedReason, { symbol: options.blockedSymbol }).label
  if (!options.isValid) {
    if (options.amountEntered) return "Enter a valid amount"
    return "Enter an amount"
  }
  if (options.stage === "configure") return "Review"
  return options.verb
}

export function shouldDisablePrimaryCta(options: {
  stage: ActionStage
  isValid: boolean
  isPending: boolean
  blockedReason?: string | null
}) {
  if (options.isPending) return true
  if (isProcessingStage(options.stage)) return true
  if (options.stage === "wallet_sign" || options.stage === "approve_allowance") return true
  if (options.blockedReason) return true
  if (options.stage === "configure" && !options.isValid) return true
  if (options.stage === "review" && !options.isValid) return true
  return false
}

export function shouldShowWalletToast(stage: ActionStage) {
  return stage === "wallet_sign" || stage === "approve_allowance"
}

export function walletToastMessage(stage: ActionStage, amountLabel: string) {
  if (stage === "approve_allowance") {
    return `To continue, approve token allowance for ${amountLabel} in your wallet.`
  }
  return `To continue, confirm ${amountLabel} in your wallet.`
}

export function reviewStageTitle(verb: string) {
  return `Review ${verb.toLowerCase()}`
}
