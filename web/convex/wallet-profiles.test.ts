// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { api, internal } from "./_generated/api"
import schema from "./schema"

const modules = import.meta.glob("./**/*.*s")
const WALLET = "0xAbC0000000000000000000000000000000000001"

describe("wallet profiles", () => {
  test("derives the wallet from auth and sanitizes merged preferences", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })

    await asUser.mutation(api.wallet.profiles.savePreferences, {
      preferences: { name: "  ElizabethAlexandra  ", language: "ZH", dexSources: ["uniswap", "  "] },
    })
    await asUser.mutation(api.wallet.profiles.savePreferences, {
      preferences: { currency: "CNY", dexSources: ["curve"] },
    })

    const profile = await asUser.query(api.wallet.profiles.getMine, {})
    expect(profile).toMatchObject({
      wallet: WALLET.toLowerCase(),
      preferences: { name: "ElizabethA", language: "ZH", currency: "CNY", dexSources: ["curve"] },
    })
  })

  test("rejects unauthenticated reads and writes", async () => {
    const t = convexTest(schema, modules)
    await expect(t.query(api.wallet.profiles.getMine, {})).rejects.toThrow(/UNAUTHENTICATED/)
    await expect(t.mutation(api.wallet.profiles.savePreferences, { preferences: { name: "Deb" } })).rejects.toThrow(
      /UNAUTHENTICATED/,
    )
  })

  test("migrates only missing permanent profiles and is idempotent", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx) => {
      await ctx.db.insert("sandboxProfiles", {
        wallet: WALLET.toLowerCase(),
        authSubject: WALLET,
        createdAt: 100,
        seedVersion: 1,
        onboardingStep: "done",
        preferences: { name: "Sandbox" },
      })
    })

    const first = await t.mutation(internal.wallet.profiles.migrateSandboxProfiles, { batchSize: 10 })
    const second = await t.mutation(internal.wallet.profiles.migrateSandboxProfiles, { batchSize: 10 })
    expect(first).toMatchObject({ migrated: 1, skippedExisting: 0, isDone: true })
    expect(second).toMatchObject({ migrated: 0, skippedExisting: 1, isDone: true })

    const profile = await t.withIdentity({ subject: WALLET }).query(api.wallet.profiles.getMine, {})
    expect(profile?.preferences?.name).toBe("Sandbox")
    expect(profile?.createdAt).toBe(100)
  })
})
