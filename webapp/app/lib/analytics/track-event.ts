import { track } from "@vercel/analytics"

/**
 * Product funnel events for Vercel Web Analytics (Analytics → Events; filter by country, device
 * and referrer there). Never send wallet addresses or amounts — only coarse labels.
 */
export type AnalyticsEvent =
  | "get_started_click"
  | "get_started_signed_in"
  | "transaction_success"
  | "ask_ai_question"
  /** A wallet finished /onboarding (funded by the local faucet). */
  | "onboarding_completed"
  /** An app action sent without its front-end fee (Q-409 (6) or a wallet without atomic batches). */
  | "fee_free_action"

export function trackEvent(name: AnalyticsEvent, properties?: Record<string, string | number | boolean>) {
  try {
    track(name, properties)
  } catch {
    // Analytics must never break the product.
  }
}
