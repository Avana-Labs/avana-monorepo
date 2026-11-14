// @vitest-environment edge-runtime
//
// Property tests (fast-check) for the umbrella recordAction lifecycle. Each
// property drives a random sequence of stake / stakeMore / claim /
// partialCooldown / unstake actions against a single market and asserts an
// invariant after every step. Uses SANDBOX_DEV_CONTROLS + advanceCooldown to
// synthesize the "cooldown finished" transition without waiting real time.
import { convexTest, type TestConvex } from "convex-test"
import { afterEach, beforeEach, describe, test } from "vitest"
import fc from "fast-check"
import schema from "./schema"
import { api } from "./_generated/api"

const modules = import.meta.glob("./**/*.*s")

type T = TestConvex<typeof schema>

const WALLET = "0xAbC0000000000000000000000000000000000001"
const MARKET = "usdc"
const DAY_MS = 24 * 60 * 60 * 1000

async function seedLiquid(t: T, amount: number) {
  await t.run(async (ctx) => {
    await ctx.db.insert("tokenPrices", {
      symbol: "usdc",
      llamaId: "test:usdc",
      priceUsd: 1,
      confidence: 0.99,
      status: "fresh",
      source: "test",
      updatedAt: Date.now(),
    })
    await ctx.db.insert("walletLiquidBalances", {
      wallet: WALLET.toLowerCase(),
      assetId: MARKET,
      symbol: "USDC",
      amount,
      valueUsd: amount,
      state: "available",
      updatedAt: Date.now(),
    })
  })
}

async function readPosition(t: T) {
  return t.run(async (ctx) => {
    return ctx.db
      .query("positions")
      .withIndex("by_wallet_product_market", (q) =>
        q.eq("wallet", WALLET.toLowerCase()).eq("product", "umbrella").eq("marketSlug", MARKET),
      )
      .unique()
  })
}

async function readLiquid(t: T) {
  return t.run(async (ctx) => {
    const row = await ctx.db
      .query("walletLiquidBalances")
      .withIndex("by_wallet_asset", (q) => q.eq("wallet", WALLET.toLowerCase()).eq("assetId", MARKET))
      .first()
    return row?.amount ?? 0
  })
}

type Action =
  | { kind: "stake"; amount: number }
  | { kind: "claim" }
  | { kind: "partialCooldown"; amount: number }
  | { kind: "unstake"; amount: number }

const actionArb: fc.Arbitrary<Action> = fc.oneof(
  fc.record({ kind: fc.constant("stake" as const), amount: fc.integer({ min: 1, max: 200 }) }),
  fc.record({ kind: fc.constant("claim" as const) }),
  fc.record({ kind: fc.constant("partialCooldown" as const), amount: fc.integer({ min: 1, max: 200 }) }),
  fc.record({ kind: fc.constant("unstake" as const), amount: fc.integer({ min: 1, max: 200 }) }),
)

describe("umbrella recordAction — lifecycle invariants (fast-check)", () => {
  beforeEach(() => {
    process.env.SANDBOX_DEV_CONTROLS = "true"
  })
  afterEach(() => {
    delete process.env.SANDBOX_DEV_CONTROLS
  })

  test("I1: walletBalances[m] never goes negative across any legal action sequence", async () => {
    await fc.assert(
      fc.asyncProperty(fc.array(actionArb, { minLength: 1, maxLength: 8 }), async (actions) => {
        const t = convexTest(schema, modules)
        await seedLiquid(t, 1000)
        const asUser = t.withIdentity({ subject: WALLET })
        let intent = 0
        for (const action of actions) {
          try {
            if (action.kind === "stake") {
              await asUser.mutation(api.sandbox.umbrella.recordAction, {
                wallet: WALLET,
                intentId: `i${intent++}`,
                kind: "stake",
                marketId: MARKET,
                amount: action.amount,
              })
            } else if (action.kind === "claim") {
              await asUser.mutation(api.sandbox.umbrella.recordAction, {
                wallet: WALLET,
                intentId: `i${intent++}`,
                kind: "claim",
                marketId: MARKET,
                amount: 0,
              })
            } else if (action.kind === "partialCooldown") {
              await asUser.mutation(api.sandbox.umbrella.recordAction, {
                wallet: WALLET,
                intentId: `i${intent++}`,
                kind: "startCooldown",
                marketId: MARKET,
                amount: action.amount,
              })
            } else {
              // Advance so unstake is possible.
              await asUser.mutation(api.sandbox.dev.advanceCooldown, {
                wallet: WALLET,
                marketId: MARKET,
                byMs: 21 * DAY_MS,
              })
              await asUser.mutation(api.sandbox.umbrella.recordAction, {
                wallet: WALLET,
                intentId: `i${intent++}`,
                kind: "unstake",
                marketId: MARKET,
                amount: action.amount,
              })
            }
          } catch {
            // Rejected transitions (INSUFFICIENT_BALANCE, NO_REWARDS, etc.) are
            // legitimate — the property is that IF a mutation succeeded, the
            // wallet balance stays ≥ 0. A rejection is a no-op so the invariant
            // still holds.
          }
          if ((await readLiquid(t)) < 0) return false
        }
        return true
      }),
      { numRuns: 8 },
    )
  })

  test("I2: position.suppliedUsd6 >= sum(active tranche amountUsd6) always (BigInt comparison)", async () => {
    await fc.assert(
      fc.asyncProperty(fc.array(actionArb, { minLength: 1, maxLength: 8 }), async (actions) => {
        const t = convexTest(schema, modules)
        await seedLiquid(t, 1000)
        const asUser = t.withIdentity({ subject: WALLET })
        let intent = 0
        for (const action of actions) {
          try {
            if (action.kind === "stake") {
              await asUser.mutation(api.sandbox.umbrella.recordAction, {
                wallet: WALLET,
                intentId: `i${intent++}`,
                kind: "stake",
                marketId: MARKET,
                amount: action.amount,
              })
            } else if (action.kind === "partialCooldown") {
              await asUser.mutation(api.sandbox.umbrella.recordAction, {
                wallet: WALLET,
                intentId: `i${intent++}`,
                kind: "startCooldown",
                marketId: MARKET,
                amount: action.amount,
              })
            } else if (action.kind === "unstake") {
              await asUser.mutation(api.sandbox.dev.advanceCooldown, {
                wallet: WALLET,
                marketId: MARKET,
                byMs: 21 * DAY_MS,
              })
              await asUser.mutation(api.sandbox.umbrella.recordAction, {
                wallet: WALLET,
                intentId: `i${intent++}`,
                kind: "unstake",
                marketId: MARKET,
                amount: action.amount,
              })
            }
          } catch {
            // Rejections are fine — see I1 comment.
          }
          const position = await readPosition(t)
          if (position) {
            const supplied = BigInt(position.suppliedUsd6 ?? "0")
            // Sum across every active tranche (multi-tranche cooldowns land
            // in umbrellaCooldownTranches; the aggregate rollup on `positions`
            // is the same sum). The invariant now spans the sum, not a
            // single-tranche field.
            const tranches = await t.run(async (ctx) =>
              ctx.db
                .query("umbrellaCooldownTranches")
                .withIndex("by_position", (q) => q.eq("positionId", position._id))
                .collect(),
            )
            let cooling = 0n
            for (const tranche of tranches) {
              if (tranche.status === "consumed") continue
              cooling += BigInt(tranche.amountUsd6)
            }
            if (supplied < cooling) return false
            // Aggregate rollup on the position row must match the sum.
            if (BigInt(position.cooldownAmountUsd6 ?? "0") !== cooling) return false
          }
        }
        return true
      }),
      { numRuns: 8 },
    )
  })

  test("I3: sum(stake) - sum(unstake) === suppliedUsd6 after any successful action sequence", async () => {
    await fc.assert(
      fc.asyncProperty(fc.array(actionArb, { minLength: 1, maxLength: 8 }), async (actions) => {
        const t = convexTest(schema, modules)
        await seedLiquid(t, 1000)
        const asUser = t.withIdentity({ subject: WALLET })
        let intent = 0
        let stakedUsd6 = 0n
        let unstakedUsd6 = 0n
        for (const action of actions) {
          if (action.kind === "stake") {
            try {
              await asUser.mutation(api.sandbox.umbrella.recordAction, {
                wallet: WALLET,
                intentId: `i${intent++}`,
                kind: "stake",
                marketId: MARKET,
                amount: action.amount,
              })
              stakedUsd6 += BigInt(action.amount) * 1_000_000n
            } catch {
              // Failed transitions leave the counter untouched.
            }
          } else if (action.kind === "partialCooldown") {
            try {
              await asUser.mutation(api.sandbox.umbrella.recordAction, {
                wallet: WALLET,
                intentId: `i${intent++}`,
                kind: "startCooldown",
                marketId: MARKET,
                amount: action.amount,
              })
            } catch {
              // no-op
            }
          } else if (action.kind === "unstake") {
            try {
              await asUser.mutation(api.sandbox.dev.advanceCooldown, {
                wallet: WALLET,
                marketId: MARKET,
                byMs: 21 * DAY_MS,
              })
              await asUser.mutation(api.sandbox.umbrella.recordAction, {
                wallet: WALLET,
                intentId: `i${intent++}`,
                kind: "unstake",
                marketId: MARKET,
                amount: action.amount,
              })
              unstakedUsd6 += BigInt(action.amount) * 1_000_000n
            } catch {
              // no-op
            }
          }
        }
        const position = await readPosition(t)
        if (!position) return stakedUsd6 - unstakedUsd6 === 0n
        // Slashing / rewards are OFF for these runs, so principal accounting
        // is exact — no rounding, no accrual leaking into suppliedUsd6.
        return BigInt(position.suppliedUsd6 ?? "0") === stakedUsd6 - unstakedUsd6
      }),
      { numRuns: 8 },
    )
  })

  test("I4: claim never mutates supplied, cooldownAmount, cooldownStartedAt, cooldownEndsAt, or withdrawalWindowEndsAt", async () => {
    await fc.assert(
      fc.asyncProperty(fc.array(actionArb, { minLength: 1, maxLength: 8 }), async (actions) => {
        const t = convexTest(schema, modules)
        await seedLiquid(t, 1000)
        const asUser = t.withIdentity({ subject: WALLET })
        let intent = 0
        for (const action of actions) {
          if (action.kind === "claim") {
            const before = await readPosition(t)
            try {
              await asUser.mutation(api.sandbox.umbrella.recordAction, {
                wallet: WALLET,
                intentId: `i${intent++}`,
                kind: "claim",
                marketId: MARKET,
                amount: 0,
              })
            } catch {
              // NO_REWARDS — no state change either way; move on.
              continue
            }
            const after = await readPosition(t)
            if (!before || !after) return false
            if (before.suppliedUsd6 !== after.suppliedUsd6) return false
            if (before.cooldownAmountUsd6 !== after.cooldownAmountUsd6) return false
            if (before.cooldownStartedAt !== after.cooldownStartedAt) return false
            if (before.cooldownEndsAt !== after.cooldownEndsAt) return false
            if (before.withdrawalWindowEndsAt !== after.withdrawalWindowEndsAt) return false
          } else {
            try {
              if (action.kind === "stake") {
                await asUser.mutation(api.sandbox.umbrella.recordAction, {
                  wallet: WALLET,
                  intentId: `i${intent++}`,
                  kind: "stake",
                  marketId: MARKET,
                  amount: action.amount,
                })
              } else if (action.kind === "partialCooldown") {
                await asUser.mutation(api.sandbox.umbrella.recordAction, {
                  wallet: WALLET,
                  intentId: `i${intent++}`,
                  kind: "startCooldown",
                  marketId: MARKET,
                  amount: action.amount,
                })
              } else if (action.kind === "unstake") {
                await asUser.mutation(api.sandbox.dev.advanceCooldown, {
                  wallet: WALLET,
                  marketId: MARKET,
                  byMs: 21 * DAY_MS,
                })
                await asUser.mutation(api.sandbox.umbrella.recordAction, {
                  wallet: WALLET,
                  intentId: `i${intent++}`,
                  kind: "unstake",
                  marketId: MARKET,
                  amount: action.amount,
                })
              }
            } catch {
              // rejected transitions are fine
            }
          }
        }
        return true
      }),
      { numRuns: 8 },
    )
  })
})
