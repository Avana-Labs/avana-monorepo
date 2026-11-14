// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { RAG } from "@convex-dev/rag"
import { createTool } from "@convex-dev/agent"
import { createOpenAI } from "@ai-sdk/openai"
import { v } from "convex/values"
import { z } from "zod"
import { ASK_AI_CONFIG } from "./lib/askAI/config"
import { AVANA_KNOWLEDGE_CHUNKS, AVANA_KNOWLEDGE_VERSION } from "./askAICorpus.generated"
import { components } from "./_generated/api"
import { internalAction, internalQuery } from "./_generated/server"

export const AVANA_RAG_NAMESPACE = "avana-knowledge"

const openai = createOpenAI({ apiKey: process.env.OPENAI_API_KEY })
const RAG_UNAVAILABLE_MESSAGE = "Avana's protocol knowledge is temporarily unavailable. Please try again shortly."

type AvanaSearchResult = {
  text: string
  entries: Array<{
    text: string
    title?: string
    metadata?: {
      sourceTitle?: string
      sourceUrl?: string
      sourceKind?: string
      version?: string
    }
  }>
  usage: { tokens: number }
}

const AVANA_SEARCH_STOPWORDS = new Set([
  "a",
  "an",
  "and",
  "are",
  "does",
  "for",
  "how",
  "in",
  "is",
  "it",
  "of",
  "on",
  "the",
  "to",
  "what",
  "when",
  "why",
  "with",
])

function corpusTerms(value: string) {
  return value
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter((term) => term.length >= 2 && !AVANA_SEARCH_STOPWORDS.has(term))
}

/** Fast local retrieval over the generated authoritative Avana corpus. */
export function searchAvanaCorpus(query: string, limit: number = ASK_AI_CONFIG.ragResultLimit): AvanaSearchResult {
  const terms = [...new Set(corpusTerms(query))]
  const boundedLimit = Math.min(Math.max(limit, 1), 8)
  const normalizedQuery = query.trim().toLowerCase()
  const ranked = AVANA_KNOWLEDGE_CHUNKS.map((chunk, index) => {
    const title = `${chunk.sourceTitle} ${chunk.locator}`.toLowerCase()
    const text = chunk.text.toLowerCase()
    const matchedTerms = terms.filter((term) => title.includes(term) || text.includes(term))
    const titleMatches = matchedTerms.filter((term) => title.includes(term)).length
    const phraseBoost = normalizedQuery.length >= 8 && text.includes(normalizedQuery) ? 8 : 0
    return { chunk, index, score: matchedTerms.length * 3 + titleMatches * 2 + phraseBoost }
  })
    .filter((entry) => entry.score > 0)
    .sort((a, b) => b.score - a.score || a.index - b.index)
    .slice(0, boundedLimit)

  const entries = ranked.map(({ chunk }) => ({
    text: `${chunk.locator}\n\n${chunk.text}`,
    title: chunk.sourceTitle,
    metadata: {
      sourceTitle: chunk.sourceTitle,
      sourceUrl: chunk.sourceUrl,
      sourceKind: chunk.sourceKind,
      version: AVANA_KNOWLEDGE_VERSION,
    },
  }))
  return {
    text: entries.map((entry) => entry.text).join("\n\n---\n\n"),
    entries,
    usage: { tokens: 0 },
  }
}

export function searchAvanaKnowledge(query: string, limit: number = ASK_AI_CONFIG.ragResultLimit) {
  return runAvanaKnowledgeSearch(async () => searchAvanaCorpus(query, limit))
}

export async function runAvanaKnowledgeSearch(search: () => Promise<AvanaSearchResult>) {
  try {
    const result = await search()
    if (result.entries.length === 0)
      return {
        status: "unavailable" as const,
        message: RAG_UNAVAILABLE_MESSAGE,
        sources: [],
        retrievalTokens: result.usage.tokens,
      }
    return {
      status: "available" as const,
      text: result.text,
      sources: result.entries.map((entry) => ({
        domain: "avana",
        title: entry.metadata?.sourceTitle ?? entry.title ?? "Avana documentation",
        locator: entry.text.split("\n", 1)[0],
        url: entry.metadata?.sourceUrl,
        kind: entry.metadata?.sourceKind,
        version: entry.metadata?.version,
      })),
      retrievalTokens: result.usage.tokens,
    }
  } catch {
    return {
      status: "unavailable" as const,
      message: RAG_UNAVAILABLE_MESSAGE,
      sources: [],
      retrievalTokens: 0,
    }
  }
}

export const avanaRag = new RAG<
  Record<string, never>,
  { sourceId: string; sourceTitle: string; sourceKind: string; sourceUrl: string; version: string }
>(components.rag, {
  textEmbeddingModel: openai.embedding("text-embedding-3-small"),
  embeddingDimension: 1_536,
})

export const ingestCorpusIfVersionChanged = internalAction({
  args: { corpusVersion: v.string(), sourceId: v.optional(v.string()) },
  handler: async (ctx, { corpusVersion, sourceId }) => {
    if (corpusVersion !== AVANA_KNOWLEDGE_VERSION)
      throw new Error(`Corpus version mismatch: expected ${AVANA_KNOWLEDGE_VERSION}`)
    if (!process.env.OPENAI_API_KEY) throw new Error("OPENAI_API_KEY is required to embed the Avana corpus")
    const sourceIds = [...new Set(AVANA_KNOWLEDGE_CHUNKS.map((chunk) => chunk.sourceId))].filter(
      (id) => !sourceId || id === sourceId,
    )
    if (sourceId && sourceIds.length === 0) throw new Error(`Unknown Avana knowledge source: ${sourceId}`)

    const results = []
    for (const id of sourceIds) {
      const chunks = AVANA_KNOWLEDGE_CHUNKS.filter((chunk) => chunk.sourceId === id)
      const first = chunks[0]
      if (!first) continue
      const result = await avanaRag.add(ctx, {
        namespace: AVANA_RAG_NAMESPACE,
        key: id,
        title: first.sourceTitle,
        contentHash: `${AVANA_KNOWLEDGE_VERSION}:${id}`,
        metadata: {
          sourceId: id,
          sourceTitle: first.sourceTitle,
          sourceKind: first.sourceKind,
          sourceUrl: first.sourceUrl,
          version: AVANA_KNOWLEDGE_VERSION,
        },
        chunks: chunks.map((chunk) => ({
          text: `${chunk.locator}\n\n${chunk.text}`,
          keywords: `${chunk.sourceTitle} ${chunk.locator} ${chunk.text}`,
        })),
      })
      results.push({ sourceId: id, status: result.status, created: result.created, tokens: result.usage.tokens })
    }
    return { version: AVANA_KNOWLEDGE_VERSION, sources: results }
  },
})

/**
 * Cost-free deploy/health check: verifies the Avana knowledge corpus is ingested
 * and current. `ok: false` means the model will lose all protocol grounding
 * (search_avana_knowledge returns "unavailable") — run
 * internal.askAIRag.ingestCorpusIfVersionChanged. Wire into a deploy smoke check
 * or a monitor so a missing/ stale ingest is caught before users hit it.
 */
export const corpusHealth = internalQuery({
  args: {},
  handler: async (ctx) => {
    const namespace = await avanaRag.getNamespace(ctx, { namespace: AVANA_RAG_NAMESPACE })
    if (!namespace)
      return { ok: false, version: AVANA_KNOWLEDGE_VERSION, entries: 0, atVersion: 0, reason: "namespace missing" }
    const page = await avanaRag.list(ctx, { namespaceId: namespace.namespaceId, status: "ready", limit: 100 })
    const atVersion = page.page.filter((entry) => entry.metadata?.version === AVANA_KNOWLEDGE_VERSION).length
    return {
      ok: atVersion > 0,
      version: AVANA_KNOWLEDGE_VERSION,
      entries: page.page.length,
      atVersion,
      reason: atVersion > 0 ? "ok" : "no ready entries at current version",
    }
  },
})

export const searchAvanaKnowledgeTool = createTool({
  description:
    "Search the authoritative Avana whitepaper, developer documentation, and FAQ. Use before answering how Avana works, protocol architecture, LP collateral, valuation, borrowing, liquidation, governance, safety, or legal questions.",
  inputSchema: z.object({ query: z.string().min(2).max(500) }),
  execute: (_ctx, { query }) => searchAvanaKnowledge(query),
})
