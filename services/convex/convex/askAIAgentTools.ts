// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { createTool } from "@convex-dev/agent"
import type { Tool } from "ai"
import { z } from "zod"
import type { Id } from "./_generated/dataModel"
import { api, internal } from "./_generated/api"

export const readPortfolioTool: Tool = createTool({
  description:
    "Read the signed-in user's authoritative Avana balances and positions. Use for wallet, balance, holdings, or portfolio questions.",
  inputSchema: z.object({}),
  execute: (ctx): Promise<unknown> => ctx.runQuery(api.askAITools.portfolio, {}),
})

export const readEngineSnapshotTool: Tool = createTool({
  description:
    "Read Avana's deterministic engine state across every product: per-product totals, projected lend yield, per-loop leverage and distance to liquidation, and the weakest health factor.",
  inputSchema: z.object({
    multiplyShockPct: z.number().min(-95).max(100).optional(),
    lendProjectionDays: z.number().int().positive().max(365).optional(),
  }),
  execute: (ctx, input): Promise<unknown> => ctx.runQuery(api.askAITools.engineSnapshot, input),
})

export const readBorrowCapacityTool: Tool = createTool({
  description:
    "Read the user's authoritative Credit Engine Borrow-product capacity, Borrow debt, health factor, and liquidation buffer. Multiply debt is separate and must not be counted as Borrow debt.",
  inputSchema: z.object({}),
  execute: (ctx): Promise<unknown> => ctx.runQuery(api.askAITools.borrowCapacity, {}),
})

export const readPositionRiskTool: Tool = createTool({
  description:
    "Read the user's open positions and deterministic Avana engine risk state. Use before discussing actual liquidation risk.",
  inputSchema: z.object({ positionId: z.string().optional() }),
  execute: (ctx, input): Promise<unknown> => ctx.runQuery(api.askAITools.positionRisk, input),
})

export const simulateBorrowTool: Tool = createTool({
  description:
    "Run Avana's deterministic read-only borrow simulation for an open position. The amount is denominated in USD for risk calculation.",
  inputSchema: z.object({
    positionId: z.string().min(1),
    additionalBorrowAmount: z.number().positive().max(1_000_000_000),
    borrowAsset: z.string().min(1).max(32),
  }),
  execute: (ctx, input): Promise<unknown> => ctx.runQuery(api.askAITools.simulateBorrow, input),
})

export const stressPositionTool: Tool = createTool({
  description:
    "Run Avana's deterministic read-only collateral stress engine. Changes are decimal returns, for example -0.2 means a 20% fall.",
  inputSchema: z.object({
    positionId: z.string().min(1),
    assetPriceChanges: z
      .array(z.object({ symbol: z.string().min(1).max(32), change: z.number().min(-0.95).max(1) }))
      .min(1)
      .max(8),
  }),
  execute: (ctx, input): Promise<unknown> => ctx.runQuery(api.askAITools.stressPosition, input),
})

export const searchMarketsTool: Tool = createTool({
  description:
    "Search Avana's canonical Convex market catalog and fresh cached provider data. Use for prices, pools, rates, liquidity, and supported markets. Never infer live values when this returns no fresh provider data.",
  inputSchema: z.object({ query: z.string().min(1).max(200), limit: z.number().int().min(1).max(20).optional() }),
  execute: (ctx, input): Promise<unknown> => ctx.runQuery(api.askAITools.searchMarkets, input),
})

export const readPoolMetricsTool: Tool = createTool({
  description: "Read fresh canonical Convex metrics for a specific Avana market or pool.",
  inputSchema: z.object({ marketId: z.string().min(1).max(160) }),
  execute: (ctx, input): Promise<unknown> => ctx.runQuery(api.askAITools.poolMetrics, input),
})

export function createAskAITurnTools(turnId: Id<"askAITurns">, prompt: string) {
  return {
    read_portfolio: createTool({
      description:
        "Read the signed-in user's authoritative Avana balances and positions. Use for wallet, balance, holdings, or portfolio questions.",
      inputSchema: z.object({}),
      execute: (ctx): Promise<unknown> => ctx.runQuery(internal.askAITools.portfolioForTurn, { turnId }),
    }),
    read_engine_snapshot: createTool({
      description:
        "Read Avana's deterministic engine state across every product at once: per-product totals, lend yield projected over lendProjectionDays, each loop's leverage, net APY, liquidation price and distance to liquidation, umbrella earnings, and the WEAKEST health factor rather than an average. Use for earnings projections and cross-product 'how are my positions doing' questions.",
      inputSchema: z.object({
        multiplyShockPct: z.number().min(-95).max(100).optional(),
        lendProjectionDays: z.number().int().positive().max(365).optional(),
      }),
      execute: (ctx, input): Promise<unknown> =>
        ctx.runQuery(internal.askAITools.engineSnapshotForTurn, { turnId, ...input }),
    }),
    read_borrow_capacity: createTool({
      description:
        "Read the user's authoritative Credit Engine Borrow-product capacity, Borrow debt, health factor, and liquidation buffer. Multiply debt is separate and must not be counted as Borrow debt.",
      inputSchema: z.object({}),
      execute: (ctx): Promise<unknown> => ctx.runQuery(internal.askAITools.borrowCapacityForTurn, { turnId }),
    }),
    read_position_risk: createTool({
      description: "Read the user's open positions and deterministic Avana engine risk state.",
      inputSchema: z.object({ positionId: z.string().optional() }),
      execute: (ctx, input): Promise<unknown> =>
        ctx.runQuery(internal.askAITools.positionRiskForTurn, { turnId, ...input }),
    }),
    simulate_borrow: createTool({
      description:
        "Run Avana's deterministic read-only borrow simulation for an open position. Returns the projected health factor and risk level, plus separately labelled interest on the additional borrow and interest on the full post-borrow debt over projectionDays (default 365). Never merge those two figures.",
      inputSchema: z.object({
        positionId: z.string().min(1),
        additionalBorrowAmount: z.number().positive().max(1_000_000_000),
        borrowAsset: z.string().min(1).max(32),
        projectionDays: z.number().int().positive().max(3_650).optional(),
      }),
      execute: (ctx, input): Promise<unknown> =>
        ctx.runQuery(internal.askAITools.simulateBorrowForTurn, { turnId, ...input }),
    }),
    stress_position: createTool({
      description: "Run Avana's deterministic read-only collateral stress engine.",
      inputSchema: z.object({
        positionId: z.string().min(1),
        assetPriceChanges: z
          .array(z.object({ symbol: z.string().min(1).max(32), change: z.number().min(-0.95).max(1) }))
          .min(1)
          .max(8),
      }),
      execute: (ctx, input): Promise<unknown> =>
        ctx.runQuery(internal.askAITools.stressPositionForTurn, { turnId, ...input }),
    }),
    search_markets: createTool({
      description:
        "Search Avana's canonical Convex market catalog for the user's current price, pool, rate, liquidity, or market question.",
      // The server already owns the exact user prompt. Do not let the model
      // weaken "AAVE token price" into "Aave markets" and change retrieval.
      inputSchema: z.object({ limit: z.number().int().min(1).max(20).optional() }),
      execute: (ctx, input): Promise<unknown> =>
        ctx.runQuery(api.askAITools.searchMarkets, { query: prompt, limit: input.limit }),
    }),
    read_pool_metrics: readPoolMetricsTool,
  }
}
