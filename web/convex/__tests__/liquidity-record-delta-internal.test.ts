// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "../schema"
import { api, internal } from "../_generated/api"

// Rooted at the convex directory so convex-test can resolve "sandbox/*".
const modules = import.meta.glob("../**/*.*s")

const WALLET = "0xAbC0000000000000000000000000000000000001"

function liquidityReader(t: ReturnType<typeof convexTest>) {
  return t.withIdentity({ subject: WALLET })
}

describe("liquidity.recordDelta is internal-only", () => {
  test("is registered as internal, not publicly callable", () => {
    // Compile-time proof: an internalMutation is absent from the public `api` type but
    // present on `internal`. If recordDelta were re-registered as a public `mutation`,
    // the @ts-expect-error would fail to error and the second line would not compile.
    // @ts-expect-error recordDelta must not be publicly callable
    void api.liquidity.recordDelta
    expect(internal.liquidity.recordDelta).toBeDefined()
  })

  test("wallet transactions cannot move the protocol liquidity ledger", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })

    const before = await liquidityReader(t).query(api.liquidity.listDeltas)
    expect(before.find((r) => r.marketSlug === "uni-v2:usdc")).toBeUndefined()

    await asUser.mutation(api.sandbox.transactions.recordTransaction, {
      wallet: WALLET,
      intentId: "i1",
      product: "borrow" as const,
      kind: "borrow",
      assetId: "uni-v2:usdc",
      marketSlug: "uni-v3-bluechip-weth-usdc",
      requestedAmountUsd6: "1000000000",
      executedAmountUsd6: "1000000000",
      amountUsd: 1000,
      simulated: true,
    })

    const after = await liquidityReader(t).query(api.liquidity.listDeltas)
    expect(after).toEqual([])
  })
})
