// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { api, internal } from "../../convex/_generated/api"
import schema from "../../convex/schema"

const modules = import.meta.glob("../../convex/**/*.*s")
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

})
