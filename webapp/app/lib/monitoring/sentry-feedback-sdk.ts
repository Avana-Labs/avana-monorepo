/**
 * Sentry's bug-report form, as NAMED re-exports in its own module so it lands in a separate
 * chunk that only an error page loads. `feedbackIntegration` is the bundled (sync) form: the
 * async variant fetches its UI from Sentry's CDN, which the CSP and ad-blockers would stop.
 */
export { feedbackIntegration, getClient } from "@sentry/nextjs"
