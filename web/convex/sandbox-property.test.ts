// @vitest-environment edge-runtime
//
// Property test (fast-check) for the recordTransaction write path. For ANY sequence of
// actions — including replayed intentIds — the two server invariants must hold:
//   1. exactly one transactions row per UNIQUE intentId (idempotency), and
//   2. wallet actions never mutate protocol-wide liquidity.
import { convexTest } from "convex-test"
import { describe, test } from "vitest"
import fc from "fast-check"
import schema from "./schema"
import { api } from "./_generated/api"

const modules = import.meta.glob("./**/*.*s")
const WALLET = "0xAbC0000000000000000000000000000000000001"
const SLUG = "uni-v2:usdc"

describe("recordTransaction — idempotency + protocol isolation", () => {
  test("protocol ledger stays empty; rows == unique intentIds", async () => {
    await fc.assert(
      fc.asyncProperty(
        fc.array(fc.record({ intentKey: fc.integer({ min: 0, max: 4 }), amount: fc.integer({ min: 1, max: 1000 }) }), {
          minLength: 1,
          maxLength: 12,
        }),
        async (actions) => {
          const t = convexTest(schema, modules)
          const asUser = t.withIdentity({ subject: WALLET })

          const firstSeenAmount = new Map<number, number>()
          for (const { intentKey, amount } of actions) {
            if (!firstSeenAmount.has(intentKey)) firstSeenAmount.set(intentKey, amount)
            await asUser.mutation(api.sandbox.transactions.recordTransaction, {
              wallet: WALLET,
              intentId: `i${intentKey}`,
              product: "borrow",
              kind: "borrow",
              assetId: SLUG,
              requestedAmountUsd6: String(amount * 1_000_000),
              executedAmountUsd6: String(amount * 1_000_000),
              amountUsd: amount,
            })
          }

          const uniqueCount = firstSeenAmount.size

          const deltas = await asUser.query(api.liquidity.listDeltas)
          const row = deltas.find((d) => d.marketSlug === SLUG)
          const activity = await asUser.query(api.sandbox.transactions.getActivity, { wallet: WALLET, limit: 200 })

          return row === undefined && activity.length === uniqueCount
        },
      ),
      { numRuns: 15 },
    )
  })
})
