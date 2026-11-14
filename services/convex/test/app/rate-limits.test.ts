// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { convexTest } from "convex-test"
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest"
import schema from "../../convex/schema"
import { api } from "../../convex/_generated/api"

const modules = import.meta.glob("../../convex/**/*.*s")
const SECRET = "test-rate-limit-secret"
const args = (value: { key: string; limit: number; windowMs: number }) => ({ ...value, secret: SECRET })

describe("rateLimits.consume — bounds + counting", () => {
  beforeEach(() => vi.stubEnv("CONVEX_RATE_LIMIT_SECRET", SECRET))
  afterEach(() => vi.unstubAllEnvs())

  test("allows hits up to the limit, then blocks", async () => {
    const t = convexTest(schema, modules)
    const first = await t.mutation(api.rateLimits.consume, args({ key: "k1", limit: 2, windowMs: 60_000 }))
    const second = await t.mutation(api.rateLimits.consume, args({ key: "k1", limit: 2, windowMs: 60_000 }))
    const third = await t.mutation(api.rateLimits.consume, args({ key: "k1", limit: 2, windowMs: 60_000 }))
    expect(first.allowed).toBe(true)
    expect(second.allowed).toBe(true)
    expect(third.allowed).toBe(false)
  })

  test("rejects an out-of-bounds limit", async () => {
    const t = convexTest(schema, modules)
    await expect(
      t.mutation(api.rateLimits.consume, args({ key: "k2", limit: 1_000_000, windowMs: 60_000 })),
    ).rejects.toThrow(/INVALID_RATE_LIMIT/)
  })

  test("rejects an out-of-bounds window", async () => {
    const t = convexTest(schema, modules)
    await expect(
      t.mutation(api.rateLimits.consume, args({ key: "k3", limit: 10, windowMs: 7 * 24 * 60 * 60 * 1000 })),
    ).rejects.toThrow(/INVALID_RATE_LIMIT/)
  })

  test("rejects an oversized key", async () => {
    const t = convexTest(schema, modules)
    await expect(
      t.mutation(api.rateLimits.consume, args({ key: "x".repeat(200), limit: 10, windowMs: 60_000 })),
    ).rejects.toThrow(/INVALID_RATE_LIMIT/)
  })

  test("rejects an empty key", async () => {
    const t = convexTest(schema, modules)
    await expect(t.mutation(api.rateLimits.consume, args({ key: "", limit: 10, windowMs: 60_000 }))).rejects.toThrow(
      /INVALID_RATE_LIMIT/,
    )
  })

  test("fails closed when no server secret is configured", async () => {
    vi.stubEnv("CONVEX_RATE_LIMIT_SECRET", "")
    const t = convexTest(schema, modules)
    await expect(t.mutation(api.rateLimits.consume, args({ key: "k4", limit: 5, windowMs: 60_000 }))).rejects.toThrow(
      /UNAUTHORIZED/,
    )
  })
})
