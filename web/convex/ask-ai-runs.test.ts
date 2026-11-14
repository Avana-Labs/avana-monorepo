// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { api } from "./_generated/api"
import schema from "./schema"
import * as askAiRunsModule from "./askAiRuns"

const modules = import.meta.glob("./**/*.*s")

const riskWidget = {
  type: "risk_summary",
  healthFactor: 1.6,
  bufferPct: 38,
  currentLtv: 0.4,
  riskLevel: "low",
}

function seedRun(t: ReturnType<typeof convexTest>, ownerSubject: string, threadId?: string) {
  return t.run((ctx) =>
    ctx.db.insert("askAiRuns", {
      ownerSubject,
      threadId,
      mode: "risk",
      queryText: "am I safe?",
      snapshotId: "snap_abc",
      asOf: 1_700_000_000_000,
      narrative: "",
      widgets: [riskWidget],
      actions: [],
      createdAt: 1_700_000_000_000,
    }),
  )
}

describe("askAiRuns", () => {
  test("exposes no public writer", () => {
    expect((askAiRunsModule as unknown as Record<string, unknown>).record).toBeUndefined()
  })

  test("reads a run back for its owner", async () => {
    const t = convexTest(schema, modules)
    const runId = await seedRun(t, "owner-1", "thread-1")
    const run = await t.withIdentity({ subject: "owner-1" }).query(api.askAiRuns.get, { runId })
    expect(run).toMatchObject({ mode: "risk", snapshotId: "snap_abc", ownerSubject: "owner-1" })
    expect(run?.widgets).toHaveLength(1)
  })

  test("does not leak another owner's run", async () => {
    const t = convexTest(schema, modules)
    const runId = await seedRun(t, "owner-1", "thread-1")
    const other = t.withIdentity({ subject: "owner-2" })
    expect(await other.query(api.askAiRuns.get, { runId })).toBeNull()
    expect(await other.query(api.askAiRuns.listByThread, { threadId: "thread-1" })).toEqual([])
  })

  test("requires a session", async () => {
    const t = convexTest(schema, modules)
    const runId = await seedRun(t, "owner-1")
    await expect(t.query(api.askAiRuns.get, { runId })).rejects.toThrow(/session required/)
  })
})
