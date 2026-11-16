import { beforeEach, describe, expect, it, vi } from "vitest"

const state = vi.hoisted(() => ({
  hasClient: true,
  session: null as { wallet: string } | null,
  mutation: vi.fn(async (..._args: unknown[]) => ({})),
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

import { recordSentHashes, recordSubmittedIntent } from "@/app/lib/intents/record-intent"

const WALLET = "0x00000000000000000000000000000000000000Aa"
const HASH = `0x${"AB".repeat(32)}` as const
const args = { chainId: 31337, wallet: WALLET, txHash: HASH, kind: "borrow" }

beforeEach(() => {
  state.hasClient = true
  state.client = true
  state.session = { wallet: WALLET.toLowerCase() }
  state.mutation.mockReset()
  state.mutation.mockResolvedValue({})
})

describe("recording a sent transaction", () => {
  it("sends the hash, chain and kind for the signed-in wallet, with the hash in lower case", async () => {
    await recordSubmittedIntent(args)
    expect(state.mutation).toHaveBeenCalledTimes(1)
    expect(state.mutation.mock.calls[0]![1]).toEqual({
      wallet: WALLET.toLowerCase(),
      chainId: 31337,
      txHash: HASH.toLowerCase(),
      kind: "borrow",
    })
  })

  it("sends nothing without a sign-in session, with a session of another wallet, without a deployment or a client", async () => {
    state.session = null
    await recordSubmittedIntent(args)
    state.session = { wallet: "0x00000000000000000000000000000000000000bb" }
    await recordSubmittedIntent(args)
    state.session = { wallet: WALLET.toLowerCase() }
    state.hasClient = false
    await recordSubmittedIntent(args)
    state.hasClient = true
    state.client = false
    await recordSubmittedIntent(args)
    expect(state.mutation).not.toHaveBeenCalled()
  })

  it("swallows a failed mutation", async () => {
    state.mutation.mockRejectedValue(new Error("INVALID_INTENT"))
    await expect(recordSubmittedIntent(args)).resolves.toBeUndefined()
  })
})

describe("recording the hashes of a sent action", () => {
  it("records each hash, skips missing ones and never throws", () => {
    const record = vi.fn(async () => {
      throw new Error("down")
    })
    expect(() =>
      recordSentHashes(record, {
        chainId: 1,
        wallet: WALLET,
        kind: "swap",
        hashes: [HASH, null, undefined, `0x${"cd".repeat(32)}`],
      }),
    ).not.toThrow()
    expect(record).toHaveBeenCalledTimes(2)
    expect(record).toHaveBeenCalledWith({ chainId: 1, wallet: WALLET, txHash: HASH, kind: "swap" })
  })
})
