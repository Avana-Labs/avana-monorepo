import { describe, expect, test } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

describe("Ask AI market job policy", () => {
  test("keeps provider networking out of the chat and Agent paths", () => {
    const agent = readFileSync(resolve("convex/askAIAgent.ts"), "utf8")
    const askAI = readFileSync(resolve("convex/askAI.ts"), "utf8")
    expect(agent).not.toMatch(/fetch\s*\(/)
    expect(askAI).not.toMatch(/fetch\s*\(/)
  })

  test("schedules market ingestion internally while keeping RAG ingestion operator-triggered", () => {
    const crons = readFileSync(resolve("convex/crons.ts"), "utf8")
    const ingestion = readFileSync(resolve("convex/askAIIngestion.ts"), "utf8")
    // Ingestion stays an internalAction (not publicly callable) but now runs on a schedule so the
    // Ask AI market cache refreshes without any per-request provider fetch.
    expect(ingestion).toContain("export const ingest = internalAction")
    expect(crons).toContain("internal.askAIIngestion.ingest")
    expect(crons).toContain('"ask ai ingest defillama pools", "3 * * * *"')
    expect(crons).toContain('"ask ai ingest aave markets", "9,39 * * * *"')
    // RAG corpus ingestion stays operator-triggered (explicit data-export approval) — no cron.
    expect(crons).not.toContain("askAIRag")
  })
})
