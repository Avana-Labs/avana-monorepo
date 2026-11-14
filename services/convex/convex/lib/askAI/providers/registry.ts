// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import type { AskAIFetch, AskAIMarketProvider } from "./contracts"
import { createLiveAskAIProviders } from "./liveAdapters"

export function createAskAIProviders(
  env: NodeJS.ProcessEnv = process.env,
  fetcher: AskAIFetch = fetch,
): AskAIMarketProvider[] {
  return createLiveAskAIProviders(env, fetcher)
}
