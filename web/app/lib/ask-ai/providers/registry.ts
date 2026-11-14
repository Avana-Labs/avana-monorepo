import type { AskAIFetch, AskAIMarketProvider } from "./contracts"
import { createLiveAskAIProviders } from "./live-adapters"

export function createAskAIProviders(
  env: NodeJS.ProcessEnv = process.env,
  fetcher: AskAIFetch = fetch,
): AskAIMarketProvider[] {
  return createLiveAskAIProviders(env, fetcher)
}
