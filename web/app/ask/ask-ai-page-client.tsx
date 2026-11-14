"use client"

import { trackEvent } from "@/app/lib/analytics/track-event"
import {
  AssistantRuntimeProvider,
  type AppendMessage,
  type ExternalThreadQueueAdapter,
  type ThreadAssistantMessagePart,
  type ThreadMessage,
  useExternalStoreRuntime,
} from "@assistant-ui/react"
import { useUIMessages } from "@convex-dev/agent/react"
import { useMutation, usePaginatedQuery, useQuery } from "convex/react"
import type { Id } from "@/convex/_generated/dataModel"
import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import type { AskAIUsage } from "@/app/lib/ask-ai/chat-protocol"
import { api } from "@/convex/_generated/api"
import { useLiveSiweToken } from "@/app/lib/siwe/use-siwe-auth"
import {
  ASK_AI_SUGGESTIONS,
  AskAIThread,
  type FriendlyAskAIError,
  toFriendlyAskAIError,
} from "./components/ask-ai-thread"
import { AskAIThreadList } from "./components/ask-ai-thread-list"
import { AskAILoadingBody } from "./components/ask-ai-skeleton"
import { buildAaveCard } from "./components/ask-ai-aave-card"
import type { AskAIFinancialResult } from "./components/ask-ai-financial-result-card"
import { AskAIMessagePartsSubscriber, type AskAIMessagePartsRow } from "./message-parts-subscriber"
import { askAiModeRunsEnabled } from "@/app/lib/ask-ai/config"
import { shouldBuildModeRunForTurn, type AskAiRun } from "@/app/lib/ask-ai/mode-run"
import { portfolioCardFor } from "@/app/lib/ask-ai/card-policy"

type PendingTurn = {
  id: string
  clientRequestId: string
  promptMessageId?: string
  prompt: string
  startedAt: number
  error?: FriendlyAskAIError
}

// Lane B persists these; Lane C only reads them and never fabricates fields
// that are absent.
type PersistedRichParts = {
  tool?: { name: string; query: string; request: string; result: string }
  retrievalChunks?: Array<{ title: string; locator: string; text: string; score?: number }>
  sources?: unknown[]
  visual?: { kind?: "aave_apy"; label: string; value: string; points: number[]; delta?: string }
  financialResults?: Array<{ kind?: string; dataProvenance?: string; payload: unknown }>
  modeRun?: AskAiRun
  usage?: AskAIUsage
}

type AskAIMetric = AskAIFinancialResult["metrics"][number]

const asObject = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" ? (value as Record<string, unknown>) : {}

const usd = (value: unknown): string | null =>
  typeof value === "number" && Number.isFinite(value)
    ? `$${value.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
    : null

const pct = (ratio: unknown): string | null =>
  typeof ratio === "number" && Number.isFinite(ratio)
    ? `${(ratio * 100).toLocaleString("en-US", { maximumFractionDigits: 1 })}%`
    : null

// Health factor: null means no debt (effectively infinite); undefined/NaN → omit the metric.
const healthFactor = (value: unknown): string | null =>
  value === null
    ? "∞"
    : typeof value === "number" && Number.isFinite(value)
      ? value.toLocaleString("en-US", { maximumFractionDigits: 2 })
      : null

const metricOf = (label: string, value: string | null, after?: string | null): AskAIMetric | null =>
  value == null ? null : after != null ? { label, value, after } : { label, value }

const dateTime = (value: unknown): string | null =>
  typeof value === "number" && Number.isFinite(value)
    ? new Date(value).toLocaleString([], {
        month: "short",
        day: "numeric",
        hour: "numeric",
        minute: "2-digit",
      })
    : null

function umbrellaStatus(row: Record<string, unknown>) {
  const status = typeof row.lifecycleStatus === "string" ? row.lifecycleStatus : "active"
  const cooldownEnd = dateTime(row.cooldownEndsAt)
  const windowEnd = dateTime(row.withdrawalWindowEndsAt)
  if (status === "coolingDown" || status === "partiallyCooling")
    return cooldownEnd ? `Cooling until ${cooldownEnd}` : "Cooling"
  if (status === "readyToUnstake") return windowEnd ? `Ready until ${windowEnd}` : "Ready to unstake"
  if (status === "cooldownExpired") return "Withdrawal window expired"
  if (status === "slashed") return "Slashed"
  if (status === "closed") return "Closed"
  return "Active"
}

// A financial tool result renders only when its verbatim payload already matches
// the card's display shape. Anything else is skipped — never fabricated.
function toFinancialResultCard(payload: unknown): AskAIFinancialResult | null {
  if (!payload || typeof payload !== "object") return null
  const record = payload as { kind?: unknown; title?: unknown; freshness?: unknown; asOf?: unknown; metrics?: unknown }
  if (typeof record.title !== "string" || !Array.isArray(record.metrics)) return null
  const metrics = record.metrics.filter(
    (metric): metric is AskAIMetric =>
      Boolean(metric) &&
      typeof metric === "object" &&
      typeof (metric as { label?: unknown }).label === "string" &&
      typeof (metric as { value?: unknown }).value === "string",
  )
  if (metrics.length === 0) return null
  const freshness =
    record.freshness === "fresh" || record.freshness === "stale" || record.freshness === "unavailable"
      ? record.freshness
      : undefined
  return {
    kind: (record.kind as AskAIFinancialResult["kind"]) ?? "portfolio",
    title: record.title,
    asOf: typeof record.asOf === "number" ? record.asOf : undefined,
    freshness,
    metrics,
  }
}

// Reshape a verbatim financial tool result into the display card, per tool kind.
// Returns null (card hidden) when the figures are absent — never invents them.
function buildFinancialCard(
  kind: string | undefined,
  payload: unknown,
  options: { includeUmbrella?: boolean } = {},
): AskAIFinancialResult | null {
  if (kind?.startsWith("aave_")) return buildAaveCard(kind, payload)
  const shaped = toFinancialResultCard(payload)
  if (shaped) return shaped
  const p = asObject(payload)
  if (p.walletRequired === true) return null
  const asOf = typeof p.asOf === "number" && p.asOf > 0 ? p.asOf : undefined
  const compact = (
    cardKind: AskAIFinancialResult["kind"],
    title: string,
    metrics: Array<AskAIMetric | null>,
  ): AskAIFinancialResult | null => {
    const clean = metrics.filter((metric): metric is AskAIMetric => metric !== null)
    return clean.length ? { kind: cardKind, title, asOf, metrics: clean } : null
  }
  const table = (
    cardKind: AskAIFinancialResult["kind"],
    title: string,
    columns: string[],
    rows: Array<{ id: string; cells: string[] }>,
    metrics: AskAIMetric[] = [],
  ): AskAIFinancialResult | null => (rows.length ? { kind: cardKind, title, asOf, metrics, columns, rows } : null)
  switch (kind) {
    case "portfolio": {
      const t = asObject(p.totals)
      const umbrellaFocused = p.focus === "umbrella"
      // Umbrella rows (and their Cooldown / Status columns) only when the question is about Umbrella.
      const showUmbrella = umbrellaFocused || options.includeUmbrella === true
      const rowsFor = (key: string) => (Array.isArray(p[key]) ? p[key].map(asObject) : null)
      const amountOf = (row: Record<string, unknown>) => {
        if (typeof row.valueUsd === "number" && Number.isFinite(row.valueUsd)) return row.valueUsd
        if (typeof row.valueUsd6 === "string" && Number.isFinite(Number(row.valueUsd6)))
          return Number(row.valueUsd6) / 1_000_000
        return 0
      }
      const signedSum = (rows: Record<string, unknown>[]) =>
        rows.reduce((sum, row) => sum + (row.state === "debt" ? -amountOf(row) : amountOf(row)), 0)
      const rawLend = rowsFor("lend")
      const rawBorrow = rowsFor("borrow")
      const rawMultiply = rowsFor("multiply")
      const rawLiquid = rowsFor("liquid")
      const liquidAssetIds = new Set((rawLiquid ?? []).map((row) => String(row.assetId ?? "")))
      const canonicalFromRows = {
        lend:
          rawLend == null
            ? undefined
            : signedSum(
                rawLend.filter((row) => !(row.state === "available" && liquidAssetIds.has(String(row.assetId ?? "")))),
              ),
        borrow:
          rawBorrow == null
            ? undefined
            : signedSum(
                rawBorrow.filter(
                  (row) =>
                    !(
                      row.state === "poolAvailable" &&
                      liquidAssetIds.has(String(row.poolId ?? row.assetId ?? row.marketId ?? ""))
                    ),
                ),
              ),
        multiply: rawMultiply == null ? undefined : signedSum(rawMultiply.filter((row) => row.state !== "collateral")),
        liquid: rawLiquid == null ? undefined : signedSum(rawLiquid),
      }
      const productRows = (
        umbrellaFocused
          ? []
          : [
              // Equity, not gross exposure, so these rows add up to the Net
              // value headline. `*Usd` counts debt as an asset (see the
              // netUsd note in convex/askAITools.ts).
              ["Lend", usd(t.lendNetValueUsd ?? canonicalFromRows.lend ?? t.lendNetUsd ?? t.lendUsd)],
              ["Borrow", usd(t.borrowNetValueUsd ?? canonicalFromRows.borrow ?? t.borrowNetUsd ?? t.borrowUsd)],
              [
                "Multiply",
                usd(t.multiplyNetValueUsd ?? canonicalFromRows.multiply ?? t.multiplyNetUsd ?? t.multiplyUsd),
              ],
              ["Liquid", usd(t.liquidNetValueUsd ?? canonicalFromRows.liquid ?? t.liquidNetUsd ?? t.liquidUsd)],
            ]
      ).flatMap(([product, value], index) =>
        value
          ? [
              {
                id: `product-${index}`,
                cells: showUmbrella ? [product ?? "", "All positions", value, "", ""] : [product ?? "", value],
              },
            ]
          : [],
      )
      const umbrellaRows =
        showUmbrella && Array.isArray(p.umbrella)
          ? p.umbrella.flatMap((position, index) => {
              const row = asObject(position)
              const value = usd(
                typeof row.suppliedUsd6 === "string" ? Number(row.suppliedUsd6) / 1_000_000 : row.suppliedUsd,
              )
              if (!value) return []
              const cooldown = usd(
                typeof row.cooldownAmountUsd6 === "string"
                  ? Number(row.cooldownAmountUsd6) / 1_000_000
                  : row.cooldownUsd,
              )
              return [
                {
                  id: `umbrella-${index}`,
                  cells: umbrellaFocused
                    ? [
                        String(row.marketSlug ?? row.marketId ?? `Position ${index + 1}`),
                        value,
                        cooldown ?? "$0.00",
                        umbrellaStatus(row),
                      ]
                    : [
                        "Umbrella",
                        String(row.marketSlug ?? row.marketId ?? `Position ${index + 1}`),
                        value,
                        cooldown ?? "$0.00",
                        umbrellaStatus(row),
                      ],
                },
              ]
            })
          : []
      return table(
        "portfolio",
        umbrellaFocused ? "Your Umbrella positions" : "Your Avana portfolio",
        umbrellaFocused
          ? ["Position", "Value", "Cooldown", "Status"]
          : showUmbrella
            ? ["Product", "Position", "Value", "Cooldown", "Status"]
            : ["Product", "Value"],
        [...productRows, ...umbrellaRows],
        (umbrellaFocused
          ? [
              metricOf("Total Umbrella", usd(t.umbrellaUsd)),
              metricOf("On cooldown", usd(asObject(p.umbrellaCooldownSummary).coolingUsd)),
              metricOf("Ready to unstake", usd(asObject(p.umbrellaCooldownSummary).readyUsd)),
            ]
          : // Lead with the figure the question actually asks for. Umbrella is
            // excluded from Net Value (it is not part of productBalances), so it
            // stays a separate metric rather than the headline.
            [metricOf("Net value", usd(t.netValueUsd)), metricOf("Umbrella", usd(t.umbrellaUsd))]
        ).filter((metric): metric is AskAIMetric => metric !== null),
      )
    }
    case "engine_snapshot": {
      const sum = asObject(p.summary)
      const days = typeof sum.lendProjectionDays === "number" ? sum.lendProjectionDays : null
      // Answer first: a projection question wants the projected figure.
      return compact("position_risk", "Engine projection", [
        metricOf(days ? `Projected yield (${days}d)` : "Projected yield", usd(sum.lendProjectedYieldUsd)),
        metricOf("Earned so far", usd(sum.lendEarnedUsd)),
        metricOf("Weakest health factor", healthFactor(sum.multiplyWeakestHealthFactor)),
        metricOf("Lend principal", usd(sum.lendPrincipalUsd)),
        metricOf("Multiply equity", usd(sum.multiplyEquityUsd)),
        metricOf("Umbrella earned", usd(sum.umbrellaEarnedUsd)),
      ])
    }
    case "borrow_capacity": {
      const c = asObject(p.capacity)
      // Answer first: "how much can I borrow" is `Available`, not collateral.
      return compact("borrow_capacity", "Borrow capacity", [
        metricOf("Available to borrow", usd(c.availableBorrowCapacityUsd)),
        metricOf("Health factor", healthFactor(c.healthFactor)),
        metricOf("Borrowed", usd(c.totalBorrowedUsd)),
        metricOf("Total capacity", usd(c.borrowCapacityUsd)),
        metricOf("Collateral", usd(c.collateralValueUsd)),
        metricOf("Current LTV", pct(c.currentLtv)),
      ])
    }
    case "position_risk": {
      const b = asObject(asObject(p.engine).borrow)
      // A risk question is answered by the health factor, not the collateral.
      return compact("position_risk", "Position risk", [
        metricOf("Health factor", healthFactor(b.healthFactor)),
        metricOf("Current LTV", pct(b.currentLtv)),
        metricOf("Collateral", usd(b.collateralValueUsd)),
        metricOf("Borrowed", usd(b.totalBorrowedUsd)),
        metricOf("Available to borrow", usd(b.availableBorrowCapacityUsd)),
      ])
    }
    case "simulate_borrow": {
      const s = asObject(p.simulation)
      const cur = asObject(s.current)
      const proj = asObject(s.projected)
      const interest = asObject(p.interestProjection)
      const interestDays = typeof interest.days === "number" ? ` (${interest.days}d)` : ""
      // Lead with the outcome, not the amount the user already named.
      return compact("position_risk", "Borrow simulation", [
        metricOf("Health factor", healthFactor(cur.healthFactor), healthFactor(proj.healthFactor)),
        metricOf("Risk level", typeof s.riskLevel === "string" ? s.riskLevel : null),
        metricOf("LTV", pct(cur.ltv), pct(proj.ltv)),
        metricOf("Remaining capacity", usd(s.remainingBorrowCapacityUsd)),
        metricOf("Additional borrow", usd(p.additionalBorrowAmount)),
        metricOf(`Interest on additional borrow${interestDays}`, usd(interest.incrementalInterestUsd)),
        metricOf(`Interest on total post-borrow debt${interestDays}`, usd(interest.totalProjectedInterestUsd)),
      ])
    }
    case "stress_position": {
      const s = asObject(p.simulation)
      const cur = asObject(s.current)
      const proj = asObject(s.projected)
      const liquidatable = s.liquidatable
      // "Would I get liquidated?" is the question; the scenario is the input.
      return compact("position_risk", "Stress test", [
        metricOf("Liquidatable", liquidatable === true ? "Yes" : liquidatable === false ? "No" : null),
        metricOf("Health factor", healthFactor(cur.healthFactor), healthFactor(proj.healthFactor)),
        metricOf("LTV", pct(cur.ltv), pct(proj.ltv)),
        metricOf("Collateral", usd(cur.collateralValueUsd), usd(proj.collateralValueUsd)),
        metricOf("Scenario change", pct(s.weightedCollateralChange)),
      ])
    }
    case "market": {
      const providerData = Array.isArray(p.providerData) ? p.providerData : []
      const markets = Array.isArray(p.markets) ? p.markets : []
      const pctApy = (value: unknown, suffix: string): string | null =>
        typeof value === "number" && Number.isFinite(value)
          ? `${value.toLocaleString("en-US", { maximumFractionDigits: 2 })}% ${suffix}`
          : null
      // Candidate rows come from BOTH the canonical Avana markets (which carry
      // supply/borrow APY + TVL) and the external provider snapshots/prices, so
      // an APY question isn't reduced to a lone token-price row when the lending
      // data lives in `markets`. Each row is scored so dedupe-by-symbol keeps the
      // most useful line: a rated market/pool beats an unrated one, which beats a
      // bare token-price row (price only, redundant with the chart).
      type MarketRow = { symbol: string; score: number; isPrice: boolean; id: string; cells: string[] }
      const candidates: MarketRow[] = []
      const showRisk = providerData.some((entry) => {
        const data = asObject(asObject(entry).data)
        return [data.maxLtvPct, data.liquidationThresholdPct, data.supplyCap, data.borrowCap].some(
          (value) => typeof value === "number",
        )
      })
      const riskCells = (data: Record<string, unknown>) =>
        showRisk
          ? [
              pctApy(data.maxLtvPct, "") ?? "Unavailable",
              pctApy(data.liquidationThresholdPct, "") ?? "Unavailable",
              typeof data.supplyCap === "number" ? data.supplyCap.toLocaleString("en-US") : "Unavailable",
              typeof data.borrowCap === "number" ? data.borrowCap.toLocaleString("en-US") : "Unavailable",
              Array.isArray(data.eModes)
                ? data.eModes
                    .map((mode) => String(asObject(mode).label ?? ""))
                    .filter(Boolean)
                    .join(", ") || "Unavailable"
                : "Unavailable",
            ]
          : []
      markets.forEach((entry, index) => {
        const m = asObject(entry)
        const label = String(m.symbol ?? m.name ?? m.slug ?? "Market")
        const rate =
          pctApy(m.supplyApyPct, "supply") ??
          pctApy(m.borrowAprPct, "borrow") ??
          pctApy(m.apyPct, "APY") ??
          "Unavailable"
        candidates.push({
          symbol: label.toLowerCase(),
          isPrice: false,
          score: 2 + (rate === "Unavailable" ? 0 : 1),
          id: `market-mkt-${index}`,
          cells: [label, rate, usd(m.tvlUsd) ?? "Unavailable", String(m.venueLabel ?? "Avana"), ...riskCells(m)],
        })
      })
      providerData.forEach((entry, index) => {
        const result = asObject(entry)
        const data = asObject(result.data)
        const label = String(data.symbol ?? data.pool ?? data.name ?? result.key ?? "Market")
        const isPrice = result.kind === "token_price"
        const rate =
          usd(data.priceUsd) ?? pctApy(data.apyPct, "APY") ?? pctApy(data.supplyApyPct, "supply") ?? "Unavailable"
        const size = usd(data.tvlUsd) ?? usd(data.sizeUsd) ?? usd(data.availableLiquidityUsd) ?? "Unavailable"
        candidates.push({
          symbol: result.kind === "lending_market" ? String(result.key) : label.toLowerCase(),
          isPrice,
          score: (isPrice ? 0 : 2) + (rate === "Unavailable" ? 0 : 1),
          id: `market-pd-${index}-${String(result.key ?? label)}`,
          cells: [
            result.source === "aave" ? `${label} · ${String(data.market ?? "Aave")}` : label,
            rate,
            size,
            result.source === "aave" ? "Aave (cached)" : String(result.source ?? "Convex"),
            ...riskCells(data),
          ],
        })
      })
      // One row per symbol, keeping the highest-scored (Map preserves insertion
      // order, and updating a key keeps its original position).
      const bySymbol = new Map<string, MarketRow>()
      for (const candidate of candidates) {
        const existing = bySymbol.get(candidate.symbol)
        if (!existing || candidate.score > existing.score) bySymbol.set(candidate.symbol, candidate)
      }
      let rows = Array.from(bySymbol.values())
      // The price chart already shows price, so drop bare token-price rows once
      // any richer market/pool row is present (removes the lone "aave $123.38
      // Unavailable" line users saw under an APY answer).
      if (rows.some((row) => !row.isPrice)) rows = rows.filter((row) => !row.isPrice)
      return table(
        "market",
        "Market results",
        [
          "Market",
          "Price or rate",
          "TVL or size",
          "Source",
          ...(showRisk ? ["Max LTV", "Liq. threshold", "Supply cap (tokens)", "Borrow cap (tokens)", "eMode"] : []),
        ],
        rows.map((row) => ({ id: row.id, cells: row.cells })),
      )
    }
    case "pool": {
      const providerData = Array.isArray(p.providerData) ? p.providerData : []
      const rows = providerData.map((entry, index) => {
        const result = asObject(entry)
        const data = asObject(result.data)
        return {
          id: `pool-${index}`,
          cells: [
            String(data.symbol ?? data.pool ?? asObject(p.market).symbol ?? "Pool"),
            usd(data.tvlUsd) ?? usd(data.liquidityUsd) ?? "Unavailable",
            typeof data.apyPct === "number" ? `${data.apyPct.toFixed(2)}%` : "Unavailable",
            String(result.source ?? "Convex"),
          ],
        }
      })
      return table("pool", "Pool metrics", ["Pool", "TVL", "APY", "Source"], rows)
    }
    default:
      return null
  }
}

const ACTIVE_THREAD_STORAGE_KEY = "avana.ask-ai.active-thread"

const assistantMetadata = () => ({
  unstable_state: null,
  unstable_annotations: [],
  unstable_data: [],
  steps: [],
  custom: {},
})
function persistedAssistantParts(messageId: string, text: string, rich?: PersistedRichParts, question?: string) {
  const parts: ThreadAssistantMessagePart[] = [{ type: "text", text }]
  if (rich?.retrievalChunks?.length) {
    parts.push({
      type: "data",
      name: "retrieval",
      data: {
        query: rich.tool?.query ?? "Avana",
        chunks: rich.retrievalChunks.map((chunk, index) => ({
          id: `${messageId}-chunk-${index}`,
          source: chunk.title,
          locator: chunk.locator,
          score: typeof chunk.score === "number" ? chunk.score : 0,
          text: chunk.text,
        })),
      },
    })
  }
  if (rich?.sources?.length) parts.push({ type: "data", name: "sources", data: rich.sources })
  if (rich?.visual)
    parts.push({ type: "data", name: rich.visual.kind === "aave_apy" ? "aave-apy" : "chart", data: rich.visual })
  for (const entry of rich?.financialResults ?? []) {
    const payload = asObject(entry.payload)
    const providerData = Array.isArray(payload.providerData) ? payload.providerData : []
    const isSingleTokenPrice =
      entry.kind === "market" && providerData.length === 1 && asObject(providerData[0]).kind === "token_price"
    if (rich?.visual && isSingleTokenPrice) continue
    // The portfolio table appears only when the question asks to see holdings; a plain
    // question ("what is my net value") is answered in the text alone.
    const portfolioCard = entry.kind === "portfolio" ? portfolioCardFor(question) : null
    if (portfolioCard && !portfolioCard.show && asObject(entry.payload).focus !== "umbrella") continue
    const card = buildFinancialCard(entry.kind, entry.payload, { includeUmbrella: portfolioCard?.includeUmbrella })
    if (card) parts.push({ type: "data", name: "financial-result", data: card })
  }
  // Deterministic mode-run cards render only when the flag is on, so a stray persisted
  // run can never surface in the default experience.
  if (rich?.modeRun && askAiModeRunsEnabled() && shouldBuildModeRunForTurn(rich.modeRun.queryText))
    parts.push({ type: "data", name: "mode-run", data: rich.modeRun })
  return parts
}

export function AskAIPageClient({
  onActiveTitleChange,
  onReadyChange,
}: {
  onActiveTitleChange?: (title: string | null) => void
  onReadyChange?: (ready: boolean) => void
} = {}) {
  // This component mounts only after hydration, so initialize the desktop
  // sidebar from the real viewport immediately. Starting at false and opening it
  // in an effect shifted the body skeleton sideways during the final handoff.
  const [threadsOpen, setThreadsOpen] = useState(() =>
    typeof window !== "undefined" && typeof window.matchMedia === "function"
      ? window.matchMedia("(min-width: 1024px)").matches
      : false,
  )
  // This component is mounted client-only (gated on useHydrated in ask-page-client), so reading
  // sessionStorage in the initializer is safe and restores the active thread on the first paint.
  const [activeThreadId, setActiveThreadId] = useState<string | null>(() =>
    typeof window === "undefined" ? null : window.sessionStorage.getItem(ACTIVE_THREAD_STORAGE_KEY),
  )
  // A newly created thread is returned before the paginated thread query can
  // include it. Keep that explicit selection stable during the subscription
  // gap instead of falling back to the previous first thread.
  const pendingActiveThreadRef = useRef<string | null>(null)
  const [draftThread, setDraftThread] = useState(false)
  // The runtime can retain an older onNew callback for one render. Keep the
  // selected thread in a ref as well, so submitting immediately after New Thread
  // cannot enqueue into the previously selected conversation.
  const activeThreadIdRef = useRef<string | null>(activeThreadId)
  const [pendingTurn, setPendingTurn] = useState<PendingTurn | null>(null)
  const {
    results: threads,
    status: threadPageStatus,
    loadMore: loadMoreThreads,
  } = usePaginatedQuery(api.askAI.listPage, { status: "active" }, { initialNumItems: 30 })
  const {
    results: archivedThreads,
    status: archivedPageStatus,
    loadMore: loadMoreArchivedThreads,
  } = usePaginatedQuery(api.askAI.listPage, { status: "archived" }, { initialNumItems: 20 })
  const resolvedActiveThreadId = threads.some((thread) => thread.threadId === activeThreadId) ? activeThreadId : null
  // Surface the active thread's subject only when the whole initial view is ready.
  const activeThreadTitle = threads.find((thread) => thread.threadId === resolvedActiveThreadId)?.title ?? null
  const quota = useQuery(api.askAI.quota, {})
  const siwe = useLiveSiweToken()
  const walletProfile = useQuery(api.wallet.profiles.getMine, siwe?.wallet ? {} : "skip") as
    { preferences?: { name?: string } } | null | undefined
  const displayName = walletProfile?.preferences?.name ?? null
  const createThread = useMutation(api.askAI.create)
  const renameThread = useMutation(api.askAI.rename)
  const archiveThread = useMutation(api.askAI.archive)
  const unarchiveThread = useMutation(api.askAI.unarchive)
  const enqueueTurn = useMutation(api.askAI.enqueueTurn)
  const cancelQueuedTurn = useMutation(api.askAI.cancelQueuedTurn)
  const retryFailedTurn = useMutation(api.askAI.retryFailedTurn)
  const cancelRunningTurn = useMutation(api.askAI.cancelRunningTurn)
  const {
    results: messageResults,
    status: messagePageStatus,
    loadMore: loadMoreMessages,
  } = useUIMessages(api.askAI.messages, resolvedActiveThreadId ? { threadId: resolvedActiveThreadId } : "skip", {
    initialNumItems: 50,
    stream: true,
  })
  const turnQueue = useQuery(
    api.askAI.turnQueue,
    resolvedActiveThreadId ? { threadId: resolvedActiveThreadId } : "skip",
  )
  const threadListsReady = threadPageStatus !== "LoadingFirstPage" && archivedPageStatus !== "LoadingFirstPage"
  const selectionReady = draftThread || threads.length === 0 || Boolean(resolvedActiveThreadId)
  const selectedThreadReady =
    !resolvedActiveThreadId || (messagePageStatus !== "LoadingFirstPage" && turnQueue !== undefined)
  const profileReady = !siwe?.wallet || walletProfile !== undefined
  const initialDataReady =
    threadListsReady && selectionReady && selectedThreadReady && quota !== undefined && profileReady
  const [hasInitialized, setHasInitialized] = useState(false)
  const contentReady = hasInitialized || initialDataReady

  useEffect(() => {
    if (initialDataReady) setHasInitialized(true)
  }, [initialDataReady])

  useEffect(() => {
    if (!contentReady) return
    onActiveTitleChange?.(activeThreadTitle && activeThreadTitle !== "New Chat" ? activeThreadTitle : null)
    onReadyChange?.(true)
  }, [activeThreadTitle, contentReady, onActiveTitleChange, onReadyChange])
  // Rich assistant parts (cards/sources) come from a separate, non-streamed query
  // (so they aren't re-fetched per streamed token) via a fail-soft subscriber that
  // can't blank the chat if that query errors. Merged into the messages by id.
  // The subscriber remounts per thread (keyed), so stale parts from a previous
  // thread simply go unmatched (message ids are globally unique) until the new
  // thread's parts load — no separate reset effect (which would race the child).
  const [messageParts, setMessageParts] = useState<AskAIMessagePartsRow[]>([])
  const richPartsByMessage = useMemo(
    () => new Map(messageParts.map((row) => [row.messageId, row.parts as PersistedRichParts | undefined])),
    [messageParts],
  )

  useEffect(() => {
    if (typeof window.matchMedia !== "function") return
    const desktop = window.matchMedia("(min-width: 1024px)")
    const sync = () => setThreadsOpen(desktop.matches)
    sync()
    desktop.addEventListener("change", sync)
    return () => desktop.removeEventListener("change", sync)
  }, [])
  useEffect(() => {
    if (threadPageStatus === "LoadingFirstPage") return
    if (resolvedActiveThreadId) {
      if (pendingActiveThreadRef.current === resolvedActiveThreadId) pendingActiveThreadRef.current = null
      return
    }
    if (draftThread && !activeThreadId) return
    if (activeThreadId && pendingActiveThreadRef.current === activeThreadId) return
    const fallbackThreadId = threads[0]?.threadId ?? null
    activeThreadIdRef.current = fallbackThreadId
    setActiveThreadId(fallbackThreadId)
  }, [activeThreadId, draftThread, resolvedActiveThreadId, threadPageStatus, threads])
  useEffect(() => {
    if (activeThreadId) window.sessionStorage.setItem(ACTIVE_THREAD_STORAGE_KEY, activeThreadId)
    else window.sessionStorage.removeItem(ACTIVE_THREAD_STORAGE_KEY)
  }, [activeThreadId])

  const persistedMessages = useMemo<ThreadMessage[]>(() => {
    // Each answer's cards depend on the question that prompted it (see portfolioCardFor).
    let lastQuestion: string | undefined
    return messageResults.flatMap((message): ThreadMessage[] => {
      const common = {
        id: message.id,
        content: [{ type: "text" as const, text: message.text }],
        createdAt: new Date(message._creationTime),
      }
      if (message.role === "user") {
        lastQuestion = message.text
        return [{ ...common, role: "user", attachments: [], metadata: { custom: {} } }]
      }
      if (message.role === "assistant")
        return [
          {
            ...common,
            content: persistedAssistantParts(
              message.id,
              message.text,
              richPartsByMessage.get(message.id),
              lastQuestion,
            ),
            role: "assistant",
            status:
              message.status === "streaming" || message.status === "pending"
                ? { type: "running" }
                : message.status === "failed"
                  ? { type: "incomplete", reason: "error" }
                  : { type: "complete", reason: "stop" },
            metadata: assistantMetadata(),
          },
        ]
      return []
    })
  }, [messageResults, richPartsByMessage])

  const handleNewThread = useCallback(() => {
    setPendingTurn(null)
    pendingActiveThreadRef.current = null
    activeThreadIdRef.current = null
    setActiveThreadId(null)
    setDraftThread(true)
  }, [])

  // Cmd/Ctrl+K starts a new chat, matching the standard new-chat shortcut.
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault()
        void handleNewThread()
      }
    }
    window.addEventListener("keydown", onKeyDown)
    return () => window.removeEventListener("keydown", onKeyDown)
  }, [handleNewThread])

  const sendPrompt = useCallback(
    async (prompt: string) => {
      if (!prompt) return
      const clientRequestId = crypto.randomUUID()
      const startedAt = Date.now()
      setPendingTurn({ id: clientRequestId, clientRequestId, prompt, startedAt })
      try {
        let threadId = activeThreadIdRef.current
        if (!threadId) {
          const created = await createThread({})
          threadId = created.threadId
          pendingActiveThreadRef.current = threadId
          activeThreadIdRef.current = threadId
          setActiveThreadId(threadId)
          setDraftThread(false)
        }
        const queued = await enqueueTurn({ threadId, prompt, clientRequestId })
        trackEvent("ask_ai_question")
        setPendingTurn((current) =>
          current?.clientRequestId === clientRequestId
            ? { ...current, id: String(queued.turnId), promptMessageId: queued.promptMessageId }
            : current,
        )
      } catch (error) {
        setPendingTurn((current) =>
          current?.clientRequestId === clientRequestId ? { ...current, error: toFriendlyAskAIError(error) } : current,
        )
      }
    },
    [createThread, enqueueTurn],
  )

  // Execution is claimed and scheduled by Convex. The browser only reflects the
  // durable state, so tabs, remounts, and duplicate subscriptions cannot run a turn.
  useEffect(() => {
    const current =
      turnQueue?.find((turn) => turn.status === "running") ??
      turnQueue?.find((turn) => turn.status === "queued") ??
      turnQueue?.find((turn) => turn.status === "failed")
    if (current) {
      setPendingTurn((pending) => {
        const id = String(current.id)
        const clientRequestId = current.clientRequestId ?? pending?.clientRequestId ?? id
        const failed = current.status === "failed"
        if (
          pending?.id === id &&
          pending.clientRequestId === clientRequestId &&
          pending.promptMessageId === current.promptMessageId &&
          pending.prompt === current.prompt &&
          Boolean(pending.error) === failed
        )
          return pending
        return {
          id,
          clientRequestId,
          promptMessageId: current.promptMessageId,
          prompt: current.prompt,
          startedAt: pending?.id === id ? pending.startedAt : Date.now(),
          ...(failed ? { error: toFriendlyAskAIError(new Error("Ask AI could not complete this response")) } : {}),
        }
      })
      return
    }
    setPendingTurn((pending) => {
      if (!pending?.promptMessageId) return pending
      const promptIndex = persistedMessages.findIndex((message) => message.id === pending.promptMessageId)
      if (promptIndex < 0) return pending
      const hasTerminalAssistant = persistedMessages
        .slice(promptIndex + 1)
        .some(
          (message) =>
            message.role === "assistant" &&
            "status" in message &&
            (message.status?.type === "complete" || message.status?.type === "incomplete"),
        )
      return hasTerminalAssistant ? null : pending
    })
  }, [persistedMessages, turnQueue])

  const handleNewMessage = useCallback(
    async (message: AppendMessage) => {
      const prompt = message.content
        .filter((part) => part.type === "text")
        .map((part) => part.text)
        .join("\n")
        .trim()
      await sendPrompt(prompt)
    },
    [sendPrompt],
  )

  const queueAdapter = useMemo<ExternalThreadQueueAdapter>(
    () => ({
      items: (turnQueue ?? [])
        // Exclude the turn currently being generated: while claimQueuedTurn flips it
        // queued -> running, it is optimistically running (pendingTurn) yet still
        // reads "queued" from the server for a beat, which showed it twice.
        .filter((turn) => turn.status === "queued" && String(turn.id) !== pendingTurn?.id)
        .map((turn) => ({
          id: String(turn.id),
          prompt: turn.prompt,
          parts: [{ type: "text" as const, text: turn.prompt }],
        })),
      steerItems: [],
      enqueue: (message) => void handleNewMessage(message),
      steer: (message) => void handleNewMessage(message),
      move: () => undefined,
      edit: (turnId, message) => {
        void cancelQueuedTurn({ turnId: turnId as Id<"askAITurns"> }).then(() => handleNewMessage(message))
      },
      remove: (turnId) => void cancelQueuedTurn({ turnId: turnId as Id<"askAITurns"> }),
    }),
    [cancelQueuedTurn, handleNewMessage, turnQueue, pendingTurn?.id],
  )

  const messages = useMemo<readonly ThreadMessage[]>(() => {
    if (!pendingTurn) return persistedMessages
    const persistedPrompt = persistedMessages.some(
      (message) => message.role === "user" && message.id === pendingTurn.promptMessageId,
    )
    const transient: ThreadMessage[] = []
    if (!persistedPrompt)
      transient.push({
        id: `${pendingTurn.id}-user`,
        role: "user",
        content: [{ type: "text", text: pendingTurn.prompt }],
        attachments: [],
        createdAt: new Date(pendingTurn.startedAt),
        metadata: { custom: {} },
      })
    const promptIndex = pendingTurn.promptMessageId
      ? persistedMessages.findIndex((message) => message.id === pendingTurn.promptMessageId)
      : -1
    const hasPersistedAssistant =
      promptIndex >= 0 && persistedMessages.slice(promptIndex + 1).some((message) => message.role === "assistant")
    if (pendingTurn.error && !hasPersistedAssistant)
      transient.push({
        id: `${pendingTurn.id}-assistant`,
        role: "assistant",
        content: [],
        status: { type: "incomplete", reason: "error", error: pendingTurn.error },
        createdAt: new Date(pendingTurn.startedAt + 1),
        metadata: assistantMetadata(),
      })
    else if (!hasPersistedAssistant)
      transient.push({
        id: `${pendingTurn.id}-assistant`,
        role: "assistant",
        content: [],
        status: { type: "running" },
        createdAt: new Date(pendingTurn.startedAt + 1),
        metadata: assistantMetadata(),
      })
    return [...persistedMessages, ...transient]
  }, [pendingTurn, persistedMessages])

  const runtime = useExternalStoreRuntime({
    messages,
    isRunning: Boolean(pendingTurn && !pendingTurn.error),
    onNew: handleNewMessage,
    onReload: async () => {
      if (!pendingTurn?.error) return
      await retryFailedTurn({ turnId: pendingTurn.id as Id<"askAITurns"> })
      setPendingTurn(null)
    },
    onCancel: async () => {
      if (!resolvedActiveThreadId) return
      await cancelRunningTurn({ threadId: resolvedActiveThreadId })
      setPendingTurn(null)
    },
    queue: queueAdapter,
    suggestions: ASK_AI_SUGGESTIONS.map((suggestion) => ({ prompt: suggestion.prompt })),
  })

  if (!contentReady) return <AskAILoadingBody />

  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <AskAIMessagePartsSubscriber threadId={resolvedActiveThreadId} onData={setMessageParts} />
      <main className="flex h-[calc(100dvh-56px)] w-full overflow-hidden lg:h-[calc(100dvh-56px)] [@media(min-height:684px)]:min-h-[620px]">
        <AskAIThreadList
          open={threadsOpen}
          activeThreadId={resolvedActiveThreadId}
          threads={threads}
          onClose={() => setThreadsOpen(false)}
          onNewThread={handleNewThread}
          onSelectThread={(threadId) => {
            setPendingTurn(null)
            setDraftThread(false)
            activeThreadIdRef.current = threadId
            setActiveThreadId(threadId)
          }}
          onRenameThread={async (threadId, title) => {
            await renameThread({ threadId, title })
          }}
          archivedThreads={archivedThreads}
          onArchiveThread={async (threadId) => {
            await archiveThread({ threadId })
            if (threadId === resolvedActiveThreadId) {
              setPendingTurn(null)
              const fallbackThreadId = threads.find((thread) => thread.threadId !== threadId)?.threadId ?? null
              activeThreadIdRef.current = fallbackThreadId
              setActiveThreadId(fallbackThreadId)
            }
          }}
          onUnarchiveThread={async (threadId) => {
            await unarchiveThread({ threadId })
            setDraftThread(false)
            activeThreadIdRef.current = threadId
            setActiveThreadId(threadId)
          }}
          quota={quota}
          canLoadMore={threadPageStatus === "CanLoadMore"}
          onLoadMore={() => loadMoreThreads(30)}
          canLoadMoreArchived={archivedPageStatus === "CanLoadMore"}
          onLoadMoreArchived={() => loadMoreArchivedThreads(20)}
        />
        <AskAIThread
          threadsOpen={threadsOpen}
          onToggleThreads={() => setThreadsOpen((open) => !open)}
          threadId={resolvedActiveThreadId}
          displayName={displayName}
          messagesRemaining={quota ? Math.max(0, quota.limit - quota.used) : null}
          loading={
            threadPageStatus === "LoadingFirstPage" ||
            (Boolean(resolvedActiveThreadId) && messagePageStatus === "LoadingFirstPage")
          }
          usage={
            richPartsByMessage.get(
              messageResults.findLast(
                (message) => message.role === "assistant" && Boolean(richPartsByMessage.get(message.id)?.usage),
              )?.id ?? "",
            )?.usage
          }
          canLoadMoreMessages={messagePageStatus === "CanLoadMore"}
          onLoadMoreMessages={() => loadMoreMessages(50)}
          queue={(turnQueue ?? []).filter((turn) => turn.status === "queued" && String(turn.id) !== pendingTurn?.id)}
          runningPrompt={pendingTurn?.error ? undefined : pendingTurn?.prompt}
          messages={messages}
          onRetry={async () => {
            if (!pendingTurn?.error) return
            await retryFailedTurn({ turnId: pendingTurn.id as Id<"askAITurns"> })
            setPendingTurn(null)
          }}
          onSend={sendPrompt}
          onCancelRunning={async () => {
            if (!resolvedActiveThreadId) return
            await cancelRunningTurn({ threadId: resolvedActiveThreadId })
            setPendingTurn(null)
          }}
          onCancelQueued={async (turnId) => {
            await cancelQueuedTurn({ turnId: turnId as Id<"askAITurns"> })
          }}
        />
      </main>
    </AssistantRuntimeProvider>
  )
}
