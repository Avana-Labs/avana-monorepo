import { v } from "convex/values"
import { internalQuery, query, type MutationCtx, type QueryCtx } from "./_generated/server"
import type { Doc } from "./_generated/dataModel"
import { ASK_AI_WALLET_REQUIRED, askAiModeRunsEnabled } from "../app/lib/ask-ai/config"
import { getAuthedWallet } from "./sandbox/auth"
import { buildPositionContext } from "../app/lib/ask-ai/position-context"
import { positionInputFromRows } from "../app/lib/ask-ai/position-context-adapter"
import {
  buildReturnsRun,
  buildRiskRun,
  buildStressRun,
  classifyAskAiMode,
  routeAskAiMode,
  shouldBuildModeRunForTurn,
  type AskAiMode,
  type AskAiRun,
} from "../app/lib/ask-ai/mode-run"

/**
 * Live read path for an Ask AI mode-run.
 *
 * `buildModeRun` (public) resolves one position → immutable PositionContext → the
 * deterministic mode assembler and returns the typed run. `buildModeRunForTurn`
 * (internal, flag-gated) is what the agent calls per turn: it classifies the prompt
 * into a mode and attaches a run to the answer's rich parts. Both share `assembleRun`.
 */

// Same rationale as convex/askAITools.ts ASK_AI_DATA_PROVENANCE: this is a sandbox-first
// app; all position data is synthetic sandbox state, so the only honest provenance is
// "sandbox" until a real connected-wallet/on-chain read path lands.
const PROVENANCE = "sandbox"

type ReadCtx = Pick<QueryCtx | MutationCtx, "auth" | "db">

async function assembleRun(
  ctx: Pick<QueryCtx | MutationCtx, "db">,
  position: Doc<"positions">,
  mode: AskAiMode,
  queryText: string,
): Promise<{ rerouted: boolean; run: AskAiRun }> {
  const market = await ctx.db
    .query("markets")
    .withIndex("by_slug", (q) => q.eq("slug", position.marketSlug))
    .first()
  const assetId = position.assetId
  const parameter = assetId
    ? await ctx.db
        .query("multiplyTokenParameters")
        .withIndex("by_symbol", (q) => q.eq("symbol", assetId))
        .unique()
    : null

  const asOf = Date.now()
  const snapshot = buildPositionContext(positionInputFromRows({ position, market, parameter, asOf }), asOf)
  const route = routeAskAiMode(queryText, mode)
  const options = { queryText, provenance: PROVENANCE }
  const run =
    route.mode === "risk"
      ? buildRiskRun(snapshot, options)
      : route.mode === "stress"
        ? buildStressRun(snapshot, options)
        : buildReturnsRun(snapshot, options)
  return { rerouted: route.rerouted, run }
}

type ModeRunResult =
  { walletRequired: true; message: string } | { walletRequired: false; rerouted: boolean; run: AskAiRun }

async function readModeRun(
  ctx: ReadCtx,
  args: { mode: AskAiMode; queryText: string; positionId: string },
): Promise<ModeRunResult> {
  const wallet = await getAuthedWallet(ctx)
  if (!wallet) return { walletRequired: true, message: ASK_AI_WALLET_REQUIRED }

  const positions = await ctx.db
    .query("positions")
    .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
    .collect()
  const position = positions.find((row) => row._id === args.positionId && row.status === "open")
  if (!position) throw new Error("Position not found")

  return { walletRequired: false, ...(await assembleRun(ctx, position, args.mode, args.queryText)) }
}

export const buildModeRun = query({
  args: {
    mode: v.union(v.literal("risk"), v.literal("returns"), v.literal("stress")),
    queryText: v.string(),
    positionId: v.string(),
  },
  handler: readModeRun,
})

/**
 * Per-turn mode-run for the agent. Returns null (never throws) whenever the feature is
 * off, the prompt isn't a mode question, the turn has no wallet, or no position/params
 * are available — so a turn without a clear mode simply falls through to the chat answer.
 */
export const buildModeRunForTurn = internalQuery({
  args: { turnId: v.id("askAITurns"), prompt: v.string(), positionId: v.optional(v.string()) },
  handler: async (ctx, { turnId, prompt, positionId }): Promise<AskAiRun | null> => {
    if (!askAiModeRunsEnabled()) return null
    const mode = classifyAskAiMode(prompt)
    if (!mode) return null
    if (!shouldBuildModeRunForTurn(prompt)) return null
    if (!positionId) return null
    const turn = await ctx.db.get(turnId)
    const wallet = turn?.wallet
    if (!wallet) return null
    const positions = await ctx.db
      .query("positions")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .collect()
    const position = positions.find(
      (row) =>
        row._id === positionId && row.status === "open" && (row.product === "borrow" || row.product === "multiply"),
    )
    if (!position) return null
    // Guard the arithmetic/read path so a malformed row never fails the turn.
    try {
      const { run } = await assembleRun(ctx, position, mode, prompt)
      return run
    } catch {
      return null
    }
  },
})
