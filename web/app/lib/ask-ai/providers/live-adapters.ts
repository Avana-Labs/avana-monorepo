import { AaveMcpClient, aaveObject, aaveRows, aaveNumber, aavePlainText, normalizeAaveMarkets } from "../aave-mcp"
import type { ActiveAskAIMarketSource, AskAIFetch, AskAIMarketProvider, AskAIMarketRecord } from "./contracts"

type ProviderOptions = { env: NodeJS.ProcessEnv; fetcher: AskAIFetch }

function finiteNumber(value: unknown): number | undefined {
  const parsed = typeof value === "number" ? value : typeof value === "string" ? Number(value) : Number.NaN
  return Number.isFinite(parsed) ? parsed : undefined
}

function readInt(value: unknown, fallback: number): number {
  const parsed = finiteNumber(value)
  return parsed === undefined ? fallback : Math.trunc(parsed)
}

async function requestJson(fetcher: AskAIFetch, url: string, init?: RequestInit): Promise<unknown> {
  const response = await fetcher(url, init)
  if (!response.ok) throw new Error(`Market provider request failed with ${response.status}`)
  return response.json()
}

abstract class LiveProvider implements AskAIMarketProvider {
  abstract readonly source: ActiveAskAIMarketSource
  constructor(protected readonly options: ProviderOptions) {}
  abstract fetch(): Promise<AskAIMarketRecord[]>

  protected record(kind: AskAIMarketRecord["kind"], key: string, payload: Record<string, unknown>, at?: number) {
    return { source: this.source, kind, key, payload, sourceUpdatedAt: at, fetchedAt: Date.now() }
  }
}

class DefiLlamaProvider extends LiveProvider {
  readonly source = "defillama" as const

  async fetch(): Promise<AskAIMarketRecord[]> {
    return this.fetchPools()
  }

  // DefiLlama's yields API aggregates pools across every major protocol (Uniswap, Curve, Balancer,
  // PancakeSwap, Aave, ...), so one request answers "best pools" questions. The endpoint returns
  // thousands of pools; we keep the top N by TVL (ASK_AI_DEFILLAMA_POOLS_LIMIT, default 250) to
  // bound the cache — a deliberate cap, not full coverage.
  private async fetchPools(): Promise<AskAIMarketRecord[]> {
    const url = this.options.env.ASK_AI_DEFILLAMA_POOLS_URL ?? "https://yields.llama.fi/pools"
    const limit = Math.min(Math.max(readInt(this.options.env.ASK_AI_DEFILLAMA_POOLS_LIMIT, 250), 1), 1_000)
    const payload = await requestJson(this.options.fetcher, url)
    const rows = payload && typeof payload === "object" ? (payload as Record<string, unknown>).data : undefined
    if (!Array.isArray(rows)) return []
    return rows
      .flatMap((raw) => {
        if (!raw || typeof raw !== "object" || Array.isArray(raw)) return []
        const row = raw as Record<string, unknown>
        const id = typeof row.pool === "string" ? row.pool : undefined
        const tvlUsd = finiteNumber(row.tvlUsd)
        if (!id || tvlUsd === undefined) return []
        return [{ id, tvlUsd, row }]
      })
      .sort((a, b) => b.tvlUsd - a.tvlUsd)
      .slice(0, limit)
      .map(({ id, tvlUsd, row }) =>
        this.record("dex_pool", `defillama:${id}`, {
          pool: id,
          project: row.project,
          chain: row.chain,
          symbol: row.symbol,
          tvlUsd,
          // Formatter-friendly alias so cached-market rendering shows TVL.
          totalValueLockedUSD: tvlUsd,
          apy: finiteNumber(row.apy),
          apyBase: finiteNumber(row.apyBase),
          apyReward: finiteNumber(row.apyReward),
          stablecoin: row.stablecoin === true,
          ilRisk: typeof row.ilRisk === "string" ? row.ilRisk : undefined,
        }),
      )
  }
}

export class AaveProvider extends LiveProvider {
  readonly source = "aave" as const

  async fetch(): Promise<AskAIMarketRecord[]> {
    const client = new AaveMcpClient(this.options.fetcher, 64, 180_000)
    const chainData = aaveObject(await client.call("get_chains", { version: "all" }))
    const chains = new Map<number, string>()
    for (const chain of [...aaveRows(chainData.v3), ...aaveRows(chainData.v4)]) {
      const id = aaveNumber(chain.chainId)
      if (id && !chain.notServed && !chain.isTestnet && !chain.isFork) chains.set(id, aavePlainText(chain.name, 60))
    }
    if (!chains.size) throw new Error("Aave MCP returned no supported chains")
    const records: AskAIMarketRecord[] = []
    // Serial, bounded reads; a 401/429 stops this run and retains the previous cache.
    for (const [chainId] of chains) {
      const data = await client.call("get_markets", { version: "all", chainId })
      for (const reserve of normalizeAaveMarkets(data, chains)) {
        const selector = reserve.selector
        records.push(
          this.record(
            "lending_market",
            `${reserve.version}:${chainId}:${selector.reserveId ?? `${selector.market}:${selector.token}`}`,
            reserve.payload,
          ),
        )
      }
    }
    if (!records.length) throw new Error("Aave MCP returned no reserves")
    return records
  }
}

export function createLiveAskAIProviders(env: NodeJS.ProcessEnv, fetcher: AskAIFetch): AskAIMarketProvider[] {
  const options = { env, fetcher }
  return [
    // Canonical token prices come from convex/prices.ts. This provider stores only cross-protocol
    // pool data, so Ask AI does not fetch or persist a duplicate price cache.
    new DefiLlamaProvider(options),
    new AaveProvider(options),
  ]
}
