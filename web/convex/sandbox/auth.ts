/**
 * Wallet-scoped authorization for sandbox functions.
 *
 * Every sandbox query/mutation that touches wallet-specific state derives the
 * wallet from the AUTHENTICATED identity (ctx.auth) and compares it to the
 * requested wallet — a client-passed wallet is never trusted on its own.
 *
 * The identity comes from whatever issuer is registered in convex/auth.config.ts
 * (Privy, or a SIWE→JWT bridge). Both surface the controlling wallet: Privy on a
 * linked-wallet claim, a SIWE JWT on `subject` (or a `wallet` claim).
 */

import { codedError } from "../codedError"
import type { MutationCtx, QueryCtx } from "../_generated/server"

type AnyCtx = Pick<QueryCtx | MutationCtx, "auth">

export async function getAuthedWallet(ctx: AnyCtx): Promise<string | null> {
  const identity = await ctx.auth.getUserIdentity()
  if (!identity) return null
  if (identity.subject.startsWith("ask-guest:")) return null
  const raw = (identity as unknown as { wallet?: string }).wallet ?? identity.subject
  return raw ? raw.toLowerCase() : null
}

export async function getAuthSubject(ctx: AnyCtx): Promise<string | null> {
  const identity = await ctx.auth.getUserIdentity()
  return identity?.subject ?? null
}

/** Require an authenticated wallet equal to `requestedWallet`; throw otherwise. */
export async function requireSandboxWallet(ctx: AnyCtx, requestedWallet: string): Promise<string> {
  const authed = await getAuthedWallet(ctx)
  if (!authed) {
    throw codedError("UNAUTHENTICATED: connect a wallet and sign in to use the sandbox.")
  }
  if (authed !== requestedWallet.toLowerCase()) {
    throw codedError("WALLET_MISMATCH: cannot read or mutate a wallet you do not control.")
  }
  return authed
}
