// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { describe, expect, test } from "vitest"
import { ASK_AI_AGENT_INSTRUCTIONS } from "../../convex/askAIAgent"
import { ASK_AI_CONFIG } from "../../convex/lib/askAI/config"

describe("Ask AI Agent configuration", () => {
  test("uses GPT-5.6 Luna without exposing a model choice", () => {
    expect(ASK_AI_CONFIG.defaultModel).toBe("gpt-5.6-luna")
  })

  test("allows relevant current events and requires authoritative financial tools", () => {
    expect(ASK_AI_AGENT_INSTRUCTIONS).toContain("public events that may affect them")
    expect(ASK_AI_AGENT_INSTRUCTIONS).toContain("web search only for genuinely recent public events")
    expect(ASK_AI_AGENT_INSTRUCTIONS).toContain("deterministic tools")
    expect(ASK_AI_AGENT_INSTRUCTIONS).toContain("search_avana_knowledge")
    expect(ASK_AI_AGENT_INSTRUCTIONS).toContain("Redirect only clearly unrelated requests")
  })

  test("keeps the agent read-only and does not promise forecasts", () => {
    expect(ASK_AI_AGENT_INSTRUCTIONS).toContain("You are read-only")
    expect(ASK_AI_AGENT_INSTRUCTIONS).toContain("uncertain scenarios")
  })

  test("uses one full Avana persona with bounded output and standard transport", () => {
    expect(ASK_AI_CONFIG.openAIServiceTier).toBe("default")
    expect(ASK_AI_CONFIG.maxOutputTokens).toBe(900)
    expect(ASK_AI_CONFIG.reasoningEffort).toBe("medium")
    expect(ASK_AI_CONFIG.textVerbosity).toBe("medium")
    expect(ASK_AI_CONFIG.recentMessageLimit).toBeLessThanOrEqual(8)
    expect(ASK_AI_CONFIG.streamThrottleMs).toBeLessThanOrEqual(250)
    expect(ASK_AI_AGENT_INSTRUCTIONS).toContain("Talk like a real person who genuinely cares")
    expect(ASK_AI_AGENT_INSTRUCTIONS).toContain("turn it into a fun next step")
  })
})
