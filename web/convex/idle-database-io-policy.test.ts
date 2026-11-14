// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, test } from "vitest"
import { internal } from "./_generated/api"
import schema from "./schema"

const modules = import.meta.glob("./**/*.*s")

describe("idle database I/O policy", () => {
  test("keeps the scheduled idle workload within the reviewed daily budget", () => {
    const crons = readFileSync(resolve("convex/crons.ts"), "utf8")
    expect(crons).toContain('"refresh token prices", { minutes: 10 }')
    expect(crons).toContain('"refresh fx rates", { hours: 1 }')
    expect(crons).not.toContain('"compact liquidity deltas"')
    expect(crons).not.toContain('"rebuild liquidity snapshot"')
    expect(crons).toContain('"ask ai ingest defillama pools", "3 * * * *"')
    expect(crons).toContain('"ask ai ingest aave markets", "9,39 * * * *"')

    const directScheduledExecutionsPerDay =
      144 + // token prices every 10 minutes
      24 + // FX hourly
      24 + // DefiLlama pools hourly
      48 + // Aave markets every 30 minutes
      1 + // daily token-price history
      1 // daily market rollup

    expect(directScheduledExecutionsPerDay).toBe(242)
    expect(24 + 48).toBeLessThanOrEqual(72)
  })

  test("does not write an unchanged full DefiLlama pool batch", async () => {
    const t = convexTest(schema, modules)
    const records = Array.from({ length: 250 }, (_, index) => ({
      source: "defillama" as const,
      kind: "dex_pool" as const,
      key: `defillama:pool-${index}`,
      payload: { project: "test", tvlUsd: 1_000_000 - index },
      fetchedAt: 100,
    }))

    await expect(t.mutation(internal.askAIIngestion.upsertRecordsMutation, { records })).resolves.toEqual({
      inserted: 250,
      updated: 0,
      unchanged: 0,
    })
    await expect(
      t.mutation(internal.askAIIngestion.upsertRecordsMutation, {
        records: records.map((record) => ({ ...record, fetchedAt: 200 })),
      }),
    ).resolves.toEqual({ inserted: 0, updated: 0, unchanged: 250 })
  })
})
