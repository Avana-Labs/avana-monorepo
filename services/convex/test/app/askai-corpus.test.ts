// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { describe, expect, test } from "vitest"
import { AVANA_KNOWLEDGE_CHUNKS, AVANA_KNOWLEDGE_VERSION } from "../../convex/askAICorpus.generated"

describe("Avana knowledge corpus", () => {
  test("contains all three supplied knowledge sources", () => {
    expect(new Set(AVANA_KNOWLEDGE_CHUNKS.map((chunk) => chunk.sourceId))).toEqual(
      new Set(["avana-whitepaper", "avana-developer-documentation", "avana-faq"]),
    )
  })

  test("uses stable unique keys and bounded embedding chunks", () => {
    const keys = AVANA_KNOWLEDGE_CHUNKS.map((chunk) => chunk.key)
    expect(new Set(keys).size).toBe(keys.length)
    expect(Math.max(...AVANA_KNOWLEDGE_CHUNKS.map((chunk) => chunk.text.length))).toBeLessThanOrEqual(3_600)
    expect(AVANA_KNOWLEDGE_CHUNKS.every((chunk) => /^[a-f0-9]{64}$/.test(chunk.contentHash))).toBe(true)
    expect(AVANA_KNOWLEDGE_VERSION).toMatch(/^[a-f0-9]{64}$/)
  })

  test("preserves authoritative liquidation and architecture material", () => {
    const corpus = AVANA_KNOWLEDGE_CHUNKS.map((chunk) => chunk.text).join("\n")
    expect(corpus).toContain("Liquidation Flow")
    expect(corpus).toContain("Borrow Spoke")
    expect(corpus).toContain("recoverable value")
  })
})
