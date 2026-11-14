// This file configures the initialization of Sentry on the client.
// The added config here will be used whenever a users loads a page in their browser.
// https://docs.sentry.io/platforms/javascript/guides/nextjs/
//
// The SDK itself is NOT imported here: a static import bundles ~63KB (gzipped) of Sentry into
// the framework chunk that must download and execute before React can hydrate. The actual
// `Sentry.init` (and its options) live in `app/lib/monitoring/sentry-client.ts` and run once
// the page is idle. Early errors are buffered and forwarded, so coverage is unchanged.

import {
  onRouterTransitionStart as forwardRouterTransitionStart,
  scheduleSentryLoad,
} from "@/app/lib/monitoring/sentry-client"

scheduleSentryLoad()

export const onRouterTransitionStart = forwardRouterTransitionStart
