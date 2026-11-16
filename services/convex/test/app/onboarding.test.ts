// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The /onboarding steps of a wallet.

import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { api } from "../../convex/_generated/api"
import schema from "../../convex/schema"

const modules = import.meta.glob("../../convex/**/*.*s")
const WALLET = "0x00000000000000000000000000000000000a11ce"

describe("onboarding", () => {
  test("walks a wallet from analysis to done and takes one seat", async () => {
    const t = convexTest(schema, modules)
    const me = t.withIdentity({ subject: WALLET })
    expect((await me.query(api.onboarding.getOnboardingGateState, { wallet: WALLET })).onboardingStep).toBe("wallet")

    expect(await me.mutation(api.onboarding.beginAnalysis, { wallet: WALLET })).toBe("analyzing")
    expect(await me.mutation(api.onboarding.startAnalysis, { wallet: WALLET })).toBe("eligible")
    expect(await me.mutation(api.onboarding.startTweet, { wallet: WALLET })).toBe("xPending")
    expect(await me.mutation(api.onboarding.confirmTweet, { wallet: WALLET, xHandle: "@avana", tweetUrl: "https://x.com/a/status/1" })).toBe("xConfirmed")
    expect(await me.mutation(api.onboarding.beginClaim, { wallet: WALLET })).toBe("claimPending")
    expect(await me.mutation(api.onboarding.claim, { wallet: WALLET })).toEqual({ status: "done", allocatedUsd: 1_000_000 })

    const gate = await me.query(api.onboarding.getOnboardingGateState, { wallet: WALLET })
    expect(gate).toMatchObject({ onboardingStep: "done", economy: null, profile: { xHandle: "avana", allocatedUsd: 1_000_000 } })
    expect(gate.profile?.eligibilityTier).toBeGreaterThanOrEqual(0.8)

    // A finished wallet stays finished and never takes a second seat.
    expect(await me.mutation(api.onboarding.beginAnalysis, { wallet: WALLET })).toBe("done")
    await me.mutation(api.onboarding.claim, { wallet: WALLET })
    const other = t.withIdentity({ subject: "0x00000000000000000000000000000000000000b0" })
    const seats = await other.query(api.onboarding.getOnboardingGateState, { wallet: "0x00000000000000000000000000000000000000b0" })
    expect(seats.economy).toMatchObject({ status: "open", userCount: 1 })
  })

  test("refuses another wallet or no sign-in", async () => {
    const t = convexTest(schema, modules)
    await expect(t.query(api.onboarding.getOnboardingGateState, { wallet: WALLET })).rejects.toThrow(/UNAUTHENTICATED/)
    const other = t.withIdentity({ subject: "0x00000000000000000000000000000000000000b0" })
    await expect(other.mutation(api.onboarding.beginAnalysis, { wallet: WALLET })).rejects.toThrow(/UNAUTHENTICATED/)
    await expect(other.mutation(api.onboarding.claim, { wallet: "0x00000000000000000000000000000000000000b0" })).rejects.toThrow(/NO_PROFILE/)
  })
})
