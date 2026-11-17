import { beforeEach, describe, expect, it, vi } from "vitest"

const state = vi.hoisted(() => ({
  hasClient: true,
  session: null as { wallet: string } | null,
  mutation: vi.fn(async (..._args: unknown[]): Promise<unknown> => ({ points: 1000, bps: 2, endsAt: 99 })),
}))

vi.mock("@/app/lib/convex/has-convex-client", () => ({
  get hasConvexClient() {
    return state.hasClient
  },
}))
vi.mock("@/app/lib/siwe/auth-store", () => ({ getSiweSession: () => state.session }))
vi.mock("@/app/lib/convex/siwe-convex-provider", () => ({ getSiweConvexClient: () => ({ mutation: state.mutation }) }))

import { maxRedeemSteps, redeemPoints } from "@/app/lib/rewards/redeem-points"

const RULES = { pointsPerStep: 1000, bpsPerStep: 2, days: 30, maxBps: 4 }
const WALLET = "0x00000000000000000000000000000000000000aa"

beforeEach(() => {
  state.hasClient = true
  state.session = { wallet: WALLET }
  state.mutation.mockReset()
  state.mutation.mockResolvedValue({ points: 1000, bps: 2, endsAt: 99 })
})

describe("how many steps can be redeemed", () => {
  it("is the points' worth, within the cap on the discount held", () => {
    expect(maxRedeemSteps(999, 0, RULES)).toBe(0)
    expect(maxRedeemSteps(1000, 0, RULES)).toBe(1)
    expect(maxRedeemSteps(9000, 0, RULES)).toBe(2)
    expect(maxRedeemSteps(9000, 2, RULES)).toBe(1)
    expect(maxRedeemSteps(9000, 4, RULES)).toBe(0)
    expect(maxRedeemSteps(9000, 5, RULES)).toBe(0)
    expect(maxRedeemSteps(2500, 0, { ...RULES, pointsPerStep: 500, bpsPerStep: 1, maxBps: 3 })).toBe(3)
  })
})

describe("redeeming", () => {
  it("sends the steps for the session wallet and returns what was redeemed", async () => {
    expect(await redeemPoints(1)).toEqual({ ok: true, points: 1000, bps: 2, endsAt: 99 })
    expect(state.mutation.mock.calls[0]![1]).toEqual({ wallet: WALLET, steps: 1 })
  })

  it("reports not ok without a session or a deployment, and on a refusal", async () => {
    state.session = null
    expect(await redeemPoints(1)).toEqual({ ok: false })
    state.session = { wallet: WALLET }
    state.hasClient = false
    expect(await redeemPoints(1)).toEqual({ ok: false })
    state.hasClient = true
    state.mutation.mockRejectedValue(new Error("REDEMPTION_CAP"))
    expect(await redeemPoints(1)).toEqual({ ok: false })
    expect(state.mutation).toHaveBeenCalledTimes(1)
  })
})
