// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "../schema"
import { api, internal } from "../_generated/api"

const modules = import.meta.glob("../**/*.*s")

describe("listRecentSupportRequests is internal-only", () => {
  test("is registered as internal, not public", () => {
    // Compile-time proof: an internalQuery is absent from the public `api` type but
    // present on `internal`. If listRecentSupportRequests were re-registered as a
    // public `query`, the @ts-expect-error would fail to error.
    // @ts-expect-error listRecentSupportRequests must not be publicly callable
    void api.support.listRecentSupportRequests
    expect(internal.support.listRecentSupportRequests).toBeDefined()
  })

  test("internal triage view returns rows via the internal reference", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: "0xAbC0000000000000000000000000000000000001" })
    await asUser.mutation(api.support.submitSupportRequest, {
      category: "account",
      topic: "login",
      message: "I cannot sign in with my wallet at all today.",
    })

    const rows = await t.query(internal.support.listRecentSupportRequests, {})
    expect(rows.length).toBe(1)
    expect(rows[0].message).toContain("cannot sign in")
  })
})
