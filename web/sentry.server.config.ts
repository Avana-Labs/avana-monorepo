// This file configures the initialization of Sentry on the server.
// The config you add here will be used whenever the server handles a request.
// https://docs.sentry.io/platforms/javascript/guides/nextjs/

import * as Sentry from "@sentry/nextjs"
import { isSentryEnabled } from "@/app/lib/monitoring/sentry-enabled"

Sentry.init({
  dsn: process.env.NEXT_PUBLIC_SENTRY_DSN,
  // Vercel deployments only: a local `next start` must not report laptop test runs as production.
  enabled: isSentryEnabled(),

  // Sampled at 10% in production to bound trace volume; raise locally if needed.
  tracesSampleRate: process.env.NODE_ENV === "production" ? 0.1 : 0,

  // Any `dataCollection` object, even an empty one, switches the SDK to collect EVERYTHING by
  // default (cookies, request bodies, user IPs). The empty placeholder did exactly that, attaching
  // the 7-day `avana_siwe` session JWT (its name matches none of the SDK's sensitive-key
  // patterns), SIWE signatures and Ask AI prompts to every server error. Headers stay on: the SDK
  // still redacts cookie/authorization headers by name.
  dataCollection: {
    cookies: false,
    userInfo: false,
    httpBodies: [],
  },
})
