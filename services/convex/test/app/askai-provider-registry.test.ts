// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { describe, expect, it, vi } from "vitest"
import { createAskAIProviders } from "../../convex/lib/askAI/providers/registry"

describe("Ask AI provider registry", () => {
  it("production configuration can only register live adapters", () => {
    expect(createAskAIProviders({}, vi.fn() as unknown as typeof fetch).map((provider) => provider.source)).toEqual([
      "defillama",
      "aave",
    ])
  })

  it("normalizes only DefiLlama pools and leaves token prices to the canonical oracle", async () => {
    const fetcher = vi.fn(
      async () =>
        new Response(
          JSON.stringify({
            data: [
              { pool: "small", project: "curve", chain: "Ethereum", symbol: "USDC-DAI", tvlUsd: 1_000, apy: 2 },
              {
                pool: "big",
                project: "uniswap-v3",
                chain: "Ethereum",
                symbol: "WETH-USDC",
                tvlUsd: 9_000_000,
                apy: 12,
              },
            ],
          }),
          { status: 200 },
        ),
    )
    const providers = createAskAIProviders({ ASK_AI_DEFILLAMA_POOLS_LIMIT: "1" }, fetcher as unknown as typeof fetch)
    const records = (await providers.find((provider) => provider.source === "defillama")?.fetch()) ?? []
    expect(fetcher).toHaveBeenCalledTimes(1)
    expect(records).toHaveLength(1)
    expect(records[0]).toMatchObject({
      source: "defillama",
      kind: "dex_pool",
      key: "defillama:big",
      payload: expect.objectContaining({
        project: "uniswap-v3",
        tvlUsd: 9_000_000,
        totalValueLockedUSD: 9_000_000,
        apy: 12,
      }),
    })
    expect(records.every((record) => record.kind === "dex_pool")).toBe(true)
  })

  it("reads multi-chain Aave MCP reserves, preserving percentage and USD units", async () => {
    const fetcher = vi.fn(async (_url, init) => {
      const { params } = JSON.parse(String(init?.body))
      const data =
        params.name === "get_chains"
          ? {
              v3: [
                { chainId: 1, name: "Ethereum" },
                { chainId: 42161, name: "Arbitrum" },
              ],
              v4: [{ chainId: 10, notServed: true }],
            }
          : {
              v3: {
                markets: [
                  {
                    chainId: params.arguments.chainId,
                    name: "Main",
                    market: "0xpool",
                    reserves: [
                      {
                        symbol: "USDC",
                        underlyingToken: "0xusdc",
                        supplyApyPct: "3.25",
                        borrowApyPct: "5.1",
                        totalSuppliedUsd: "1000000",
                        availableLiquidity: { value: "500001", usd: "500000" },
                      },
                    ],
                  },
                ],
              },
              v4: { markets: [] },
            }
      return new Response(JSON.stringify({ result: { structuredContent: { data } } }), {
        headers: { "content-type": "application/json" },
      })
    })
    const records = await createAskAIProviders({}, fetcher as typeof fetch)
      .find((provider) => provider.source === "aave")!
      .fetch()
    expect(fetcher).toHaveBeenCalledTimes(3)
    expect(fetcher).toHaveBeenCalledWith("https://mcp.aave.com", expect.objectContaining({ method: "POST" }))
    expect(records).toHaveLength(2)
    expect(records[0]!.payload).toMatchObject({
      symbol: "USDC",
      sizeUsd: 1000000,
      supplyApyPct: 3.25,
      variableBorrowRate: 5.1,
      availableLiquidity: 500000,
    })
    expect(records[0]!.payload.market).toContain("Ethereum")
    expect(records[1]!.payload.market).toContain("Arbitrum")
    expect(records[0]!.key).not.toBe(records[1]!.key)
  })
})
