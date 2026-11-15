// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// SIWE sessions. The web app's server verifies the SIWE signature, mints the session JWT with a random JWT ID and
// opens the session here; on logout it revokes it (or every session of the wallet). Convex keeps the SHA-256 of the
// JWT ID, never the token. A Convex JWT that carries the session's ID as its `sid` claim authorizes a per-wallet
// feature only while the session is open (`walletAuth.requireWalletSession`), so a logout takes effect before the
// short Convex JWT expires.
//
// The mutations are public because their only caller is the web app's server through an external Convex client; each
// requires `CONVEX_SESSION_SECRET`, compared in constant time, and fails closed when it is unset.

import { v } from "convex/values";
import { codedError } from "./codedError";
import { internalMutation, mutation, query } from "./_generated/server";

/** The longest session the server may open. */
export const MAX_SESSION_MS = 7 * 24 * 60 * 60 * 1000;
const SESSION_ID = /^[0-9a-f]{64}$/;
const WALLET = /^0x[0-9a-f]{40}$/;

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export function checkSessionSecret(secret: string): void {
  const required = process.env.CONVEX_SESSION_SECRET;
  if (!required || required.length < 32 || !safeEqual(secret, required)) throw codedError("UNAUTHORIZED: session secret required");
}

/** Whether a session row authorizes requests at `now`. */
export function sessionActive(row: { expiresAt: number; revokedAt?: number } | null, now: number): boolean {
  return row !== null && row.revokedAt === undefined && row.expiresAt > now;
}

export const open = mutation({
  args: { secret: v.string(), sessionId: v.string(), wallet: v.string(), expiresAt: v.number() },
  handler: async (ctx, { secret, sessionId, wallet, expiresAt }) => {
    checkSessionSecret(secret);
    const w = wallet.toLowerCase();
    const now = Date.now();
    if (!SESSION_ID.test(sessionId)) throw codedError("INVALID_SESSION: sessionId is a lower-case SHA-256 hex digest");
    if (!WALLET.test(w)) throw codedError("INVALID_SESSION: wallet is a 20-byte address");
    if (!Number.isFinite(expiresAt) || expiresAt <= now || expiresAt > now + MAX_SESSION_MS) throw codedError("INVALID_SESSION: expiry must be within 7 days");
    const existing = await ctx.db.query("siweSessions").withIndex("by_session", (q) => q.eq("sessionId", sessionId)).unique();
    if (existing) {
      if (existing.wallet !== w) throw codedError("INVALID_SESSION: session belongs to another wallet");
      return { opened: false };
    }
    await ctx.db.insert("siweSessions", { sessionId, wallet: w, issuedAt: now, expiresAt });
    return { opened: true };
  },
});

export const revoke = mutation({
  args: { secret: v.string(), sessionId: v.string() },
  handler: async (ctx, { secret, sessionId }) => {
    checkSessionSecret(secret);
    const row = await ctx.db.query("siweSessions").withIndex("by_session", (q) => q.eq("sessionId", sessionId)).unique();
    if (!row || row.revokedAt !== undefined) return { revoked: false };
    await ctx.db.patch(row._id, { revokedAt: Date.now() });
    return { revoked: true };
  },
});

/** "Sign out everywhere": revokes every open session of the wallet. */
export const revokeWallet = mutation({
  args: { secret: v.string(), wallet: v.string() },
  handler: async (ctx, { secret, wallet }) => {
    checkSessionSecret(secret);
    const now = Date.now();
    let revoked = 0;
    for (const row of await ctx.db.query("siweSessions").withIndex("by_wallet", (q) => q.eq("wallet", wallet.toLowerCase())).collect()) {
      if (!sessionActive(row, now)) continue;
      await ctx.db.patch(row._id, { revokedAt: now });
      revoked += 1;
    }
    return { revoked };
  },
});

/** For the server's cookie check: whether the session is open. */
export const status = query({
  args: { secret: v.string(), sessionId: v.string() },
  handler: async (ctx, { secret, sessionId }) => {
    checkSessionSecret(secret);
    const row = await ctx.db.query("siweSessions").withIndex("by_session", (q) => q.eq("sessionId", sessionId)).unique();
    return { active: sessionActive(row, Date.now()), wallet: row?.wallet ?? null, expiresAt: row?.expiresAt ?? null };
  },
});

/** Daily: deletes sessions expired more than a day ago, in bounded batches. */
export const prune = internalMutation({
  args: {},
  handler: async (ctx) => {
    const old = await ctx.db
      .query("siweSessions")
      .withIndex("by_expiry", (q) => q.lt("expiresAt", Date.now() - 24 * 60 * 60 * 1000))
      .take(500);
    for (const row of old) await ctx.db.delete(row._id);
    return { deleted: old.length };
  },
});
