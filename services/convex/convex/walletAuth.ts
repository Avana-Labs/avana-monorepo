// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
/**
 * Wallet-scoped authorization for the per-wallet app features (preferences, support requests,
 * Ask AI). Every query/mutation that touches wallet-specific state derives the wallet from the
 * AUTHENTICATED identity (ctx.auth) and compares it to the requested wallet — a client-passed
 * wallet is never trusted on its own.
 *
 * The identity comes from the SIWE→JWT issuer registered in `auth.config.ts`: the controlling
 * wallet is the JWT `subject` (or a `wallet` claim). Protocol data never needs it.
 */

import { codedError } from "./codedError"
import type { MutationCtx, QueryCtx } from "./_generated/server"

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
export async function requireWallet(ctx: AnyCtx, requestedWallet: string): Promise<string> {
  const authed = await getAuthedWallet(ctx)
  if (!authed) {
    throw codedError("UNAUTHENTICATED: connect a wallet and sign in.")
  }
  if (authed !== requestedWallet.toLowerCase()) {
    throw codedError("WALLET_MISMATCH: cannot read or mutate a wallet you do not control.")
  }
  return authed
}
