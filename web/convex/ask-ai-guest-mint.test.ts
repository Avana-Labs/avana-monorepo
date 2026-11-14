// @vitest-environment edge-runtime
import { register as registerRateLimiter } from "@convex-dev/rate-limiter/test"
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

describe("Ask AI guest mint authorization", () => {
  test("rejects direct callers that do not know the server secret", async () => {
    process.env.CONVEX_RATE_LIMIT_SECRET = "server-only-secret"
    const t = convexTest(schema, modules)
    registerRateLimiter(t)
    await expect(
      t.mutation(api.askAI.recordGuestMint, { ip: "203.0.113.7", secret: "attacker-secret" }),
    ).rejects.toThrow(/UNAUTHORIZED/)
    await expect(
      t.mutation(api.askAI.recordGuestMint, { ip: "203.0.113.7", secret: "server-only-secret" }),
    ).resolves.toMatchObject({ ok: true })
  })
})
