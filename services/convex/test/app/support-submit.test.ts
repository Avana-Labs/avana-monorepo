// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "../../convex/schema"
import { api, internal } from "../../convex/_generated/api"
import { MAX_REQUESTS_PER_HOUR } from "../../convex/support"

const modules = import.meta.glob("../../convex/**/*.*s")

const WALLET = "0xAbC0000000000000000000000000000000000001"

function request(overrides: Record<string, unknown> = {}) {
  return {
    category: "account",
    topic: "login",
    message: "I cannot sign in with my wallet at all today.",
    ...overrides,
  }
}

describe("submitSupportRequest — auth, server-derived wallet, rate limit, bounds", () => {
  test("rejects unauthenticated calls", async () => {
    const t = convexTest(schema, modules)
    await expect(t.mutation(api.support.submitSupportRequest, request())).rejects.toThrow(/UNAUTHENTICATED/)
  })

  test("derives the wallet from the authed identity, not the client", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await asUser.mutation(api.support.submitSupportRequest, request())

    const rows = await t.query(internal.support.listRecentSupportRequests, {})
    expect(rows).toHaveLength(1)
    // Wallet comes from ctx.auth (lowercased), regardless of anything the client sends.
    expect(rows[0]!.wallet).toBe(WALLET.toLowerCase())
  })

  test("enforces the message minimum length", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(asUser.mutation(api.support.submitSupportRequest, request({ message: "too short" }))).rejects.toThrow(
      /at least/,
    )
  })

  test("rate-limits after the hourly per-wallet cap", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    for (let i = 0; i < MAX_REQUESTS_PER_HOUR; i++) {
      await asUser.mutation(api.support.submitSupportRequest, request({ message: `report number ${i} here please` }))
    }
    await expect(asUser.mutation(api.support.submitSupportRequest, request())).rejects.toThrow(/RATE_LIMITED/)
  })
})
