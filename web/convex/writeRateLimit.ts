/**
 * Per-identity write throttle for sandbox mutations.
 *
 * `requireSandboxWallet` (convex/sandbox/auth.ts) proves ownership but does NOT bound how fast a
 * wallet may write, so the append-only / state mutations that guard on it alone (onboarding steps,
 * rewards save/claim) had no ceiling on write volume. The high-traffic execution
 * path (recordTransaction / recordSwap) already caps itself at MAX_TX_PER_HOUR, and umbrella /
 * liquidation carry their own hourly caps — this fills the gap for the rest.
 *
 * Backed by the shared @convex-dev/rate-limiter component (its own storage — no schema table), so the
 * counter is correct across Convex instances. The bucket is per identity KEY (wallet or Ask AI
 * subject), so wallets never contend on a shared row. The cap is deliberately generous: a legit flow
 * writes a handful of rows, so 300/min/identity never trips while still bounding a spray.
 */
import { codedError } from "./codedError"
import { RateLimiter } from "@convex-dev/rate-limiter"
import { components } from "./_generated/api"
import type { MutationCtx } from "./_generated/server"
import { requireSandboxWallet } from "./sandbox/auth"

const writeRateLimiter = new RateLimiter(components.rateLimiter, {
  perIdentityWrite: { kind: "token bucket", rate: 300, period: 60_000, capacity: 300 },
})

/** Consume one write token for `key` (e.g. `wallet:0x…` or `subject:…`); throw when the bucket is dry. */
export async function consumeWriteBudget(ctx: MutationCtx, key: string): Promise<void> {
  let allowed: boolean
  try {
    allowed = (await writeRateLimiter.limit(ctx, "perIdentityWrite", { key })).ok
  } catch {
    // Fail OPEN when the rate-limiter component is unavailable (unit tests that don't register it, or a
    // transient component error): this is a generous anti-spray ceiling, not a security boundary, so it
    // must never turn a legit write into an error. Deployed Convex always has the component present
    // (convex.config.ts), where the throttle enforces normally. Mirrors rateLimitShared's fallback.
    allowed = true
  }
  if (!allowed) {
    throw codedError("RATE_LIMITED: too many sandbox writes in a short window; please retry shortly.")
  }
}

/** `requireSandboxWallet` + a per-wallet write throttle. Use in place of `requireSandboxWallet` in
 *  wallet-scoped mutations that persist state but have no throttle of their own. */
export async function requireSandboxWalletForWrite(ctx: MutationCtx, requestedWallet: string): Promise<string> {
  const wallet = await requireSandboxWallet(ctx, requestedWallet)
  await consumeWriteBudget(ctx, `wallet:${wallet}`)
  return wallet
}
