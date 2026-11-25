import { beforeEach, describe, expect, it, vi } from "vitest"

const state = vi.hoisted(() => ({
  hasClient: true,
  session: null as { wallet: string } | null,
  mutation: vi.fn(async (..._args: unknown[]) => ({ awarded: true })),
  client: true,
}))

vi.mock("@/app/lib/convex/has-convex-client", () => ({
  get hasConvexClient() {
    return state.hasClient
  },
}))
vi.mock("@/app/lib/siwe/auth-store", () => ({ getSiweSession: () => state.session }))
vi.mock("@/app/lib/convex/siwe-convex-provider", () => ({
  getSiweConvexClient: () => (state.client ? { mutation: state.mutation } : null),
}))

import { pinMarket, recordClientQuest } from "@/app/lib/rewards/record-client-quest"

const WALLET = "0x00000000000000000000000000000000000000aa"

beforeEach(() => {
  state.hasClient = true
  state.client = true
  state.session = { wallet: WALLET }
  state.mutation.mockReset()
  state.mutation.mockResolvedValue({ awarded: true })
})

describe("recording a client quest", () => {
  it("sends the quest for the signed-in wallet", async () => {
    await recordClientQuest("review-risk-basics")
    expect(state.mutation).toHaveBeenCalledTimes(1)
    expect(state.mutation.mock.calls[0]![1]).toEqual({ wallet: WALLET, questId: "review-risk-basics" })
  })

  it("sends nothing without a session, a deployment or a client", async () => {
    state.session = null
    await recordClientQuest("connect-wallet")
    state.session = { wallet: WALLET }
    state.hasClient = false
    await recordClientQuest("connect-wallet")
    state.hasClient = true
    state.client = false
    await recordClientQuest("connect-wallet")
    expect(state.mutation).not.toHaveBeenCalled()
  })

  it("swallows a failed mutation", async () => {
    state.mutation.mockRejectedValue(new Error("INVALID_QUEST"))
    await expect(recordClientQuest("connect-wallet")).resolves.toBeUndefined()
  })
})

describe("pinning a market", () => {
  it("sends the scope and slug for the signed-in wallet and reports the pin", async () => {
    expect(await pinMarket("pool", "ethereum-usdc-usdt")).toBe(true)
    expect(state.mutation.mock.calls[0]![1]).toEqual({ wallet: WALLET, scope: "pool", slug: "ethereum-usdc-usdt" })
  })

  it("reports false without a session, a deployment or a client, and on a failed mutation", async () => {
    state.session = null
    expect(await pinMarket("lend", "x")).toBe(false)
    state.session = { wallet: WALLET }
    state.hasClient = false
    expect(await pinMarket("lend", "x")).toBe(false)
    state.hasClient = true
    state.client = false
    expect(await pinMarket("lend", "x")).toBe(false)
    state.client = true
    state.mutation.mockRejectedValue(new Error("INVALID_PIN"))
    expect(await pinMarket("lend", "x")).toBe(false)
    expect(state.mutation).toHaveBeenCalledTimes(1)
  })
})
