// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, it } from "vitest"
import schema from "../schema"
import { api } from "../_generated/api"

const modules = import.meta.glob("../**/*.*s")
const WALLET = "0xAbC0000000000000000000000000000000000001"

function rewardState(eventId?: string) {
  return JSON.stringify({
    events: eventId
      ? [{ id: eventId, wallet: WALLET, product: "profile", type: "wallet_connected", timestamp: 1 }]
      : [],
    claims: [],
  })
}

describe("sandbox rewards OCC", () => {
  it("p1-10: saveState requires expectedRevision when a row already exists", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await asUser.mutation(api.sandbox.rewards.saveState, {
      wallet: WALLET,
      stateJson: rewardState(),
    })

    await expect(
      asUser.mutation(api.sandbox.rewards.saveState, {
        wallet: WALLET,
        stateJson: rewardState("e1"),
      }),
    ).rejects.toThrow(/REVISION_REQUIRED/)
  })

  it("p1-10: saveState reports stale expectedRevision without overwriting", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await asUser.mutation(api.sandbox.rewards.saveState, {
      wallet: WALLET,
      stateJson: rewardState(),
    })

    await asUser.mutation(api.sandbox.rewards.saveState, {
      wallet: WALLET,
      expectedRevision: 0,
      stateJson: rewardState("e1"),
    })

    const result = await asUser.mutation(api.sandbox.rewards.saveState, {
      wallet: WALLET,
      expectedRevision: 0,
      stateJson: rewardState("e2"),
    })
    expect(result).toMatchObject({ revision: 1, stale: true })

    const state = await asUser.query(api.sandbox.rewards.getState, { wallet: WALLET })
    expect(state?.stateJson).toBe(rewardState("e1"))
  })
})
