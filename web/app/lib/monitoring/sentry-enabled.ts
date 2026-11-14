/**
 * Whether Sentry may report: a production build deployed on Vercel. Literal `process.env` reads
 * so Next inlines both values into the client bundle.
 */
export function isSentryEnabled() {
  return process.env.NODE_ENV === "production" && process.env.NEXT_PUBLIC_AVANA_SENTRY_DEPLOYED === "1"
}
