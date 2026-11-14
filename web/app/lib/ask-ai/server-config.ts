import "server-only"

import { ASK_AI_CONFIG } from "./config"

function readPositiveInteger(value: string | undefined, fallback: number) {
  if (value == null || value.trim() === "") return fallback
  const parsed = Number(value)
  if (!Number.isSafeInteger(parsed) || parsed <= 0) throw new Error(`Expected a positive integer, received ${value}`)
  return parsed
}

export function getAskAIServerConfig() {
  return {
    model: process.env.ASK_AI_MODEL?.trim() || ASK_AI_CONFIG.defaultModel,
    maxOutputTokens: readPositiveInteger(process.env.ASK_AI_MAX_OUTPUT_TOKENS, ASK_AI_CONFIG.maxOutputTokens),
    providers: {
      openAIConfigured: Boolean(process.env.OPENAI_API_KEY),
    },
  }
}
