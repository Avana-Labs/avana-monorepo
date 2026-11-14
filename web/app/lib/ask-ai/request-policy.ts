import type { SystemModelMessage } from "ai"
import { ASK_AI_CONFIG } from "./config"

export function askAIRequestPolicy(env: Record<string, string | undefined> = process.env) {
  const serviceTier = env.ASK_AI_SERVICE_TIER?.trim() || ASK_AI_CONFIG.openAIServiceTier
  if (serviceTier !== "default" && serviceTier !== "fast") throw Error("ASK_AI_SERVICE_TIER must be default or fast")
  return { serviceTier, reasoningEffort: ASK_AI_CONFIG.reasoningEffort, textVerbosity: ASK_AI_CONFIG.textVerbosity }
}

/** Only the shared prefix receives a cache breakpoint; changing wallet data follows it. */
export function askAIInstructions(shared: string, dynamic?: string): SystemModelMessage[] {
  return [
    { role: "system", content: shared, providerOptions: { openai: { promptCacheBreakpoint: { mode: "explicit" } } } },
    ...(dynamic ? [{ role: "system" as const, content: dynamic }] : []),
  ]
}
