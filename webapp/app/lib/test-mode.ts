/**
 * Dev "open gate" — injects TEST_MODE_WALLET_ADDRESS and skips onboarding/auth so you can
 * iterate without connecting a wallet (live Convex; Playwright uses its own mock + session).
 *
 * Enable locally with `NEXT_PUBLIC_DEV_OPEN_GATE=1` in `.env.local`; `0` exercises the real
 * auth flow. It can NEVER activate in a deploy: `isProductionBuild()` hard-returns false
 * under NODE_ENV="production" regardless of any env flag.
 */

/**
 * Local-only Lighthouse audit build (isolated output dir, rejected in CI/Vercel) so audits can
 * measure product routes without onboarding.
 *
 * SECURITY: the NODE_ENV !== "production" guard is load-bearing. The audit vars are
 * NEXT_PUBLIC_, so a bundle built with them and deployed to a host that sets neither VERCEL
 * nor CI (self-hosted Node, Docker) would otherwise flip `isProductionBuild()` false and
 * auto-open the dev gate. It does not affect the local audit, which renders
 * LighthouseAuditSurface via the independent `isLighthouseAuditMode()`.
 */
function isLocalLighthouseAuditBuild(): boolean {
  return (
    process.env.NODE_ENV !== "production" &&
    process.env.NEXT_PUBLIC_LIGHTHOUSE_AUDIT_MODE === "1" &&
    process.env.NEXT_PUBLIC_LIGHTHOUSE_AUDIT_ARTIFACT === "1" &&
    !process.env.VERCEL &&
    !process.env.CI
  )
}

/** Hard floor: the open gate is impossible in every deploy build. */
function isProductionBuild(): boolean {
  return process.env.NODE_ENV === "production" && !isLocalLighthouseAuditBuild()
}

/** Explicit local opt-in for day-to-day coding. Set in `.env.local` (gitignored). */
function isDevOpenGateEnabled(): boolean {
  return process.env.NEXT_PUBLIC_DEV_OPEN_GATE === "1"
}

/** e2e opt-in — Playwright sets this on its dev server (see playwright.config.ts). */
export function isPlaywrightTestMode(): boolean {
  return process.env.NEXT_PUBLIC_PLAYWRIGHT_TEST_MODE === "1"
}

/** Local Lighthouse route audit opt-in. It shares the production hard floor below. */
export function isLighthouseAuditMode(): boolean {
  return process.env.NEXT_PUBLIC_LIGHTHOUSE_AUDIT_MODE === "1"
}

export function shouldUseOpenGateSession(): boolean {
  if (isProductionBuild()) return false
  return isDevOpenGateEnabled() || isPlaywrightTestMode() || isLighthouseAuditMode()
}

export const IS_DEV_SHORTCUT_MODE = shouldUseOpenGateSession()
export const IS_OPEN_GATE_TEST_MODE = IS_DEV_SHORTCUT_MODE

/** Wallet the dev open gate and Playwright authenticate as (never a real SIWE subject). */
export const TEST_MODE_WALLET_ADDRESS = "0x0000000000000000000000000000000000000a11"
