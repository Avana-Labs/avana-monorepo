import { v } from "convex/values"
import { internalQuery } from "./_generated/server"

const DAY_MS = 24 * 60 * 60 * 1000
/** Upper bound on rows scanned per table, so the report stays inside Convex's read limits. */
const MAX_ROWS = 20_000

type DayRow = {
  newWallets: number
  onboarded: number
  activeWallets: number
  transactions: number
  byProduct: Record<string, number>
}

/**
 * Read-only product usage summary for the team (internal: not callable from the browser):
 *   npx convex run usageReport:summary '{"days": 14}'
 * Per UTC day: wallets that started onboarding, wallets that finished it, wallets that made a
 * successful transaction, and successful transactions by product. Pairs with Vercel Analytics,
 * which covers traffic (country, device, referrer) — this covers what signed-in wallets do.
 */
export const summary = internalQuery({
  args: { days: v.optional(v.number()) },
  handler: async (ctx, { days }) => {
    const windowDays = Math.min(Math.max(Math.floor(days ?? 14), 1), 90)
    const since = Date.now() - windowDays * DAY_MS
    const dayOf = (at: number) => new Date(at).toISOString().slice(0, 10)
    const byDay: Record<string, DayRow> = {}
    const row = (day: string) =>
      (byDay[day] ??= { newWallets: 0, onboarded: 0, activeWallets: 0, transactions: 0, byProduct: {} })

    const profiles = await ctx.db.query("sandboxProfiles").take(MAX_ROWS)
    let onboardedTotal = 0
    for (const profile of profiles) {
      if (profile.onboardingStep === "done") onboardedTotal += 1
      if (profile.createdAt >= since) row(dayOf(profile.createdAt)).newWallets += 1
      if (profile.onboardedAt !== undefined && profile.onboardedAt >= since)
        row(dayOf(profile.onboardedAt)).onboarded += 1
    }

    const transactions = await ctx.db
      .query("transactions")
      .withIndex("by_creation_time", (q) => q.gte("_creationTime", since))
      .take(MAX_ROWS)
    const activeByDay: Record<string, Set<string>> = {}
    const byProductTotal: Record<string, number> = {}
    for (const tx of transactions) {
      if (tx.status !== "success") continue
      const day = dayOf(tx._creationTime)
      const entry = row(day)
      entry.transactions += 1
      entry.byProduct[tx.product] = (entry.byProduct[tx.product] ?? 0) + 1
      byProductTotal[tx.product] = (byProductTotal[tx.product] ?? 0) + 1
      ;(activeByDay[day] ??= new Set()).add(tx.wallet)
    }
    for (const [day, wallets] of Object.entries(activeByDay)) row(day).activeWallets = wallets.size

    return {
      windowDays,
      totals: {
        wallets: profiles.length,
        onboarded: onboardedTotal,
        transactionsInWindow: Object.values(byProductTotal).reduce((sum, count) => sum + count, 0),
        byProductInWindow: byProductTotal,
      },
      truncated: profiles.length === MAX_ROWS || transactions.length === MAX_ROWS,
      daily: Object.fromEntries(Object.entries(byDay).sort(([a], [b]) => (a < b ? 1 : -1))),
    }
  },
})
