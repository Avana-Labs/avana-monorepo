import type { MutationCtx, QueryCtx } from "../_generated/server"

type SessionCtx = QueryCtx | MutationCtx
type SessionWrite = {
  wallet: string
  authSubject?: string
  seedVersion: number
  seededAt?: number
  lastSeenAt: number
  umbrellaSeeded?: boolean
}

export async function readWalletSession(ctx: SessionCtx, wallet: string) {
  return ctx.db
    .query("walletSessions")
    .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
    .unique()
}

export async function upsertWalletSession(ctx: MutationCtx, session: SessionWrite) {
  const current = await readWalletSession(ctx, session.wallet)
  if (current) await ctx.db.patch(current._id, session)
  else await ctx.db.insert("walletSessions", session)
}
