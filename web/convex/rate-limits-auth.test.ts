// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { afterEach, describe, expect, test } from "vitest"
import { api } from "./_generated/api"
import schema from "./schema"

const modules = import.meta.glob("./**/*.*s")
const originalSecret = process.env.CONVEX_RATE_LIMIT_SECRET

afterEach(() => {
  if (originalSecret === undefined) delete process.env.CONVEX_RATE_LIMIT_SECRET
  else process.env.CONVEX_RATE_LIMIT_SECRET = originalSecret
})

describe("shared rate-limit authorization", () => {
  test("rejects direct bucket poisoning and accepts the server secret", async () => {
    process.env.CONVEX_RATE_LIMIT_SECRET = "server-only-secret"
    const t = convexTest(schema, modules)
    await expect(
      t.mutation(api.rateLimits.consume, {
        key: "siwe-nonce:victim-ip",
        limit: 30,
        windowMs: 60_000,
        secret: "attacker-secret",
      }),
    ).rejects.toThrow(/UNAUTHORIZED/)
    await expect(
      t.mutation(api.rateLimits.consume, {
        key: "siwe-nonce:victim-ip",
        limit: 30,
        windowMs: 60_000,
        secret: "server-only-secret",
      }),
    ).resolves.toMatchObject({ allowed: true, remaining: 29 })
  })
})
