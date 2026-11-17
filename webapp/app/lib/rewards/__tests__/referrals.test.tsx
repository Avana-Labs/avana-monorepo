import { render, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"

const state = vi.hoisted(() => ({
  hasClient: true,
  session: null as { wallet: string } | null,
  mutation: vi.fn(async (..._args: unknown[]): Promise<unknown> => ({ result: "attributed" })),
}))

vi.mock("@/app/lib/convex/has-convex-client", () => ({
  get hasConvexClient() {
    return state.hasClient
  },
}))
vi.mock("@/app/lib/siwe/auth-store", () => ({ getSiweSession: () => state.session }))
vi.mock("@/app/lib/siwe/use-siwe-auth", () => ({ useSiweToken: () => state.session }))
vi.mock("@/app/lib/convex/siwe-convex-provider", () => ({ getSiweConvexClient: () => ({ mutation: state.mutation }) }))

import { ReferralCapture } from "@/app/components/referral-capture"
import { ReferralAttributionSync } from "@/app/lib/rewards/referral-attribution-sync"
import {
  attributeReferral,
  clearStoredReferralCode,
  fetchMyReferralCode,
  getStoredReferralCode,
  referralCodeFromSearch,
  referralLink,
  storeReferralCode,
} from "@/app/lib/rewards/referrals"

const WALLET = "0x00000000000000000000000000000000000000aa"

beforeEach(() => {
  state.hasClient = true
  state.session = null
  state.mutation.mockReset()
  state.mutation.mockResolvedValue({ result: "attributed" })
  window.localStorage.clear()
  window.history.replaceState({}, "", "/")
})

describe("referral codes in the app", () => {
  it("reads a well-formed code from the query string, lower-cased, and nothing else", () => {
    expect(referralCodeFromSearch("?ref=ABCD2345")).toBe("abcd2345")
    expect(referralCodeFromSearch("?x=1&ref=abcd2345")).toBe("abcd2345")
    for (const bad of ["", "?ref=", "?ref=abcd234", "?ref=abcd2340", "?ref=abcd23456", "?ref=abcd 345"]) {
      expect(referralCodeFromSearch(bad), bad).toBeNull()
    }
  })

  it("keeps the first code and ignores a later one or a malformed one", () => {
    storeReferralCode("abcd2345")
    storeReferralCode("zzzz2222")
    storeReferralCode("bad")
    expect(getStoredReferralCode()).toBe("abcd2345")
    clearStoredReferralCode()
    expect(getStoredReferralCode()).toBeNull()
  })

  it("builds the link from the origin and the code", () => {
    expect(referralLink("https://app.example.com/", "abcd2345")).toBe("https://app.example.com/?ref=abcd2345")
  })
})

describe("capturing a referral link", () => {
  it("stores the code of the first visit", () => {
    window.history.replaceState({}, "", "/?ref=abcd2345")
    render(<ReferralCapture />)
    expect(getStoredReferralCode()).toBe("abcd2345")
  })

  it("stores nothing without a valid code", () => {
    window.history.replaceState({}, "", "/?ref=nope")
    render(<ReferralCapture />)
    expect(getStoredReferralCode()).toBeNull()
  })
})

describe("attributing after sign-in", () => {
  it("attributes the signed-in wallet and forgets the code", async () => {
    storeReferralCode("abcd2345")
    state.session = { wallet: WALLET }
    render(<ReferralAttributionSync />)
    await waitFor(() => expect(getStoredReferralCode()).toBeNull())
    expect(state.mutation.mock.calls[0]![1]).toEqual({ wallet: WALLET, code: "abcd2345" })
  })

  it("forgets the code whatever Convex answered, but keeps it when the call failed", async () => {
    storeReferralCode("abcd2345")
    state.session = { wallet: WALLET }
    state.mutation.mockResolvedValue({ result: "self" })
    render(<ReferralAttributionSync />)
    await waitFor(() => expect(getStoredReferralCode()).toBeNull())

    storeReferralCode("abcd2345")
    state.mutation.mockRejectedValue(new Error("down"))
    render(<ReferralAttributionSync />)
    await waitFor(() => expect(state.mutation).toHaveBeenCalledTimes(2))
    expect(getStoredReferralCode()).toBe("abcd2345")
  })

  it("does nothing while signed out or without a stored code", () => {
    storeReferralCode("abcd2345")
    render(<ReferralAttributionSync />)
    state.session = { wallet: WALLET }
    clearStoredReferralCode()
    render(<ReferralAttributionSync />)
    expect(state.mutation).not.toHaveBeenCalled()
  })
})

describe("calls to Convex", () => {
  it("attributes and reads the code for the session wallet, and gives null without a session or a deployment", async () => {
    expect(await attributeReferral("abcd2345")).toBeNull()
    expect(await fetchMyReferralCode()).toBeNull()
    state.session = { wallet: WALLET }
    state.mutation.mockResolvedValueOnce({ result: "not_new" })
    expect(await attributeReferral("abcd2345")).toBe("not_new")
    state.mutation.mockResolvedValueOnce({ code: "wxyz2345" })
    expect(await fetchMyReferralCode()).toBe("wxyz2345")
    state.hasClient = false
    expect(await attributeReferral("abcd2345")).toBeNull()
    expect(await fetchMyReferralCode()).toBeNull()
  })
})
