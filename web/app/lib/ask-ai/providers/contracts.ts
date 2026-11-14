export type AskAIMarketSource = "coingecko" | "defillama" | "aave"
export type ActiveAskAIMarketSource = Exclude<AskAIMarketSource, "coingecko">

export type AskAIMarketRecord = {
  source: AskAIMarketSource
  kind: "token_price" | "dex_pool" | "lending_market"
  key: string
  payload: Record<string, unknown>
  sourceUpdatedAt?: number
  fetchedAt: number
}

export interface AskAIMarketProvider {
  readonly source: ActiveAskAIMarketSource
  fetch(): Promise<AskAIMarketRecord[]>
}

export type AskAIFetch = typeof fetch
