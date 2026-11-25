/**
 * Build-time value of `NEXT_PUBLIC_AVANA_SENTRY_DEPLOYED` (set in next.config.mjs): "1" only when
 * the build runs on Vercel. A local `next build` / `next start` still has the DSN from `.env.local`
 * and a production NODE_ENV, and would otherwise report laptop test runs as production errors.
 *
 * @param {Record<string, string | undefined>} env
 */
export function sentryDeploymentFlag(env) {
  return env.VERCEL ? "1" : "0"
}
