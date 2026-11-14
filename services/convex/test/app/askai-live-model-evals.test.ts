// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { createOpenAI } from "@ai-sdk/openai"
import { generateText, stepCountIs, tool } from "ai"
import { afterAll, describe, expect, it } from "vitest"
import { z } from "zod"
import { ASK_AI_AGENT_INSTRUCTIONS } from "../../convex/askAIAgent"
import { ASK_AI_CONFIG } from "../../convex/lib/askAI/config"

const enabled = process.env.RUN_ASK_AI_LIVE_EVALS === "1" && Boolean(process.env.OPENAI_API_KEY)
const live = enabled ? describe : describe.skip
const openai = createOpenAI({ apiKey: process.env.OPENAI_API_KEY })

const usageReport: Array<{
  prompt: string
  tokens: number
  cacheRead: number
  cacheWrite: number
  durationMs: number
}> = []

const fixtures = [
  { prompt: "sup", expectedTool: null, required: /(?:hey|hi|help|what)/i },
  { prompt: "what's in my wallet balance?", expectedTool: "read_portfolio", required: /\$19,720/ },
  {
    prompt: "How much can I borrow?",
    expectedTool: "read_borrow_capacity",
    required: /(?:borrow|capacity|available)/i,
  },
  {
    prompt:
      "What is my exact net value in the Avana sandbox? Give the component values and the final total, with no rounding.",
    expectedTool: "read_portfolio",
    required: /(?:net value|component|total)/i,
  },
  {
    prompt:
      "What is my current weakest health factor across all positions, and which position has it? Give the exact value and the liquidation buffer.",
    expectedTool: "read_position_risk",
    required: /(?:health factor|liquidation|buffer)/i,
  },
  {
    prompt:
      "If all of my collateral falls by 20%, what is the exact resulting health factor, liquidation status, and collateral loss? Use the weakest position, not the first position.",
    expectedTool: "stress_position",
    required: /(?:health factor|liquidat|collateral)/i,
  },
  {
    prompt:
      "How much will my Lend positions earn over the next 30 days? Give each position's principal, APY, projected yield, and the exact total. Do not calculate from rounded card values.",
    expectedTool: "read_engine_snapshot",
    required: /(?:30|yield|earn)/i,
  },
  {
    prompt:
      "If I borrow exactly $1,000 more against my current Borrow position, what will my health factor, remaining capacity, and 30-day interest be? Use the position's actual APR.",
    expectedTool: "simulate_borrow",
    required: /(?:health|capacity|interest|apr)/i,
  },
  {
    prompt:
      "What is the current GHO supply APY and borrow APR in Avana? Give the exact source values and do not confuse APY with APR or token price.",
    expectedTool: "search_markets",
    required: /(?:apy|apr|gho)/i,
  },
  {
    prompt: "will I get liquidated if ETH falls 20%?",
    expectedTool: "stress_position",
    required: /(?:health|liquidat|risk)/i,
  },
  {
    prompt: "Explain Avana LP collateral valuation",
    expectedTool: "search_avana_knowledge",
    required: /(?:recover|liquid|collateral|nav)/i,
  },
  {
    prompt: "President Trump and the SEC are making a crypto announcement. What could it do to markets?",
    expectedTool: "web_search",
    required: /(?:scenario|uncertain|could|risk|market)/i,
  },
] as const

live("Ask AI live Luna evaluations", () => {
  afterAll(() => console.warn("Ask AI evaluation usage", JSON.stringify(usageReport)))
  it.each(fixtures)(
    "answers $prompt with the expected grounded behavior",
    async ({ prompt, expectedTool, required }) => {
      const startedAt = Date.now()
      const calls: string[] = []
      const result = await generateText({
        model: openai(process.env.ASK_AI_MODEL?.trim() || ASK_AI_CONFIG.defaultModel),
        system: ASK_AI_AGENT_INSTRUCTIONS,
        prompt,
        stopWhen: stepCountIs(4),
        maxOutputTokens: ASK_AI_CONFIG.maxOutputTokens,
        maxRetries: 0,
        abortSignal: AbortSignal.timeout(60_000),
        providerOptions: { openai: { serviceTier: "default", reasoningEffort: ASK_AI_CONFIG.reasoningEffort } },
        tools: {
          read_portfolio: tool({
            description: "Read authoritative wallet balances",
            inputSchema: z.object({}),
            execute: async () => {
              calls.push("read_portfolio")
              return { totals: { umbrellaUsd: 19_720, liquidUsd: 69_670 }, asOf: Date.now() }
            },
          }),
          read_borrow_capacity: tool({
            description: "Read authoritative Borrow-product capacity and debt",
            inputSchema: z.object({}),
            execute: async () => {
              calls.push("read_borrow_capacity")
              return { availableBorrowCapacityUsd: 245_000, borrowCapacityUsd: 495_000, totalBorrowedUsd: 250_000 }
            },
          }),
          read_position_risk: tool({
            description: "Read authoritative position risk and weakest health factor",
            inputSchema: z.object({ positionId: z.string().optional() }),
            execute: async () => {
              calls.push("read_position_risk")
              return { weakestHealthFactor: 2, liquidationBuffer: null, asOf: Date.now() }
            },
          }),
          read_engine_snapshot: tool({
            description: "Read authoritative cross-product projections",
            inputSchema: z.object({ lendProjectionDays: z.number().optional() }),
            execute: async () => {
              calls.push("read_engine_snapshot")
              return { lendProjectionDays: 30, lendProjectedYieldUsd: 91.12244741640544, asOf: Date.now() }
            },
          }),
          simulate_borrow: tool({
            description: "Simulate an additional borrow and return separate incremental and total interest",
            inputSchema: z.object({
              positionId: z.string(),
              additionalBorrowAmount: z.number(),
              borrowAsset: z.string(),
              projectionDays: z.number().optional(),
            }),
            execute: async () => {
              calls.push("simulate_borrow")
              return {
                simulation: { projected: { healthFactor: 50.815792344 } },
                interestProjection: { incrementalInterestUsd: 4.002739726, totalProjectedInterestUsd: 17.58 },
              }
            },
          }),
          stress_position: tool({
            description: "Run authoritative position stress",
            inputSchema: z.object({}),
            execute: async () => {
              calls.push("stress_position")
              return { projectedHealthFactor: 1.18, shock: { ETH: -0.2 }, asOf: Date.now() }
            },
          }),
          search_markets: tool({
            description: "Read current Avana market rates and prices",
            inputSchema: z.object({ query: z.string() }),
            execute: async () => {
              calls.push("search_markets")
              return { markets: [{ symbol: "GHO", supplyApyPct: 2.92, borrowAprPct: 4.87 }] }
            },
          }),
          search_avana_knowledge: tool({
            description: "Search authoritative Avana documentation",
            inputSchema: z.object({ query: z.string() }),
            execute: async () => {
              calls.push("search_avana_knowledge")
              return {
                text: "Avana values LP collateral by recoverable unwind value and liquidity-aware risk controls.",
              }
            },
          }),
          web_search: tool({
            description: "Search current public information",
            inputSchema: z.object({ query: z.string() }),
            execute: async () => {
              calls.push("web_search")
              return { results: [{ title: "Current crypto policy announcement", date: "2026-08-20" }] }
            },
          }),
        },
      })

      usageReport.push({
        prompt,
        tokens: result.usage.totalTokens ?? 0,
        cacheRead: result.usage.inputTokenDetails.cacheReadTokens ?? 0,
        cacheWrite: result.usage.inputTokenDetails.cacheWriteTokens ?? 0,
        durationMs: Date.now() - startedAt,
      })
      if (expectedTool) expect(calls).toContain(expectedTool)
      else expect(calls).toHaveLength(0)
      expect(result.text).toMatch(required)
      expect(result.text).not.toMatch(/domain[_ ]guard|unsupported category|system prompt/i)
    },
    90_000,
  )
})
