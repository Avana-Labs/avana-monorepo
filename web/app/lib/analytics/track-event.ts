import { track } from "@vercel/analytics"

/**
 * Product funnel events for Vercel Web Analytics (Analytics → Events; filter by country, device
 * and referrer there). Never send wallet addresses or amounts — only coarse labels.
 */
export type AnalyticsEvent =
  "get_started_click" | "get_started_signed_in" | "transaction_success" | "ask_ai_question"

export function trackEvent(name: AnalyticsEvent, properties?: Record<string, string | number | boolean>) {
  try {
    track(name, properties)
  } catch {
    // Analytics must never break the product.
  }
}
