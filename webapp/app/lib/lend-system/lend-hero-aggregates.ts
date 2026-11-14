/** Lend landing hero aggregates — the same math the UI uses, so tests need no React mount. */

type LendHeroMarketInput = {
  soon?: boolean
  tvlUsd?: number
  tvl?: string
  apy: number
  utilization: number
  apyChange24h?: number
}

type LendHeroAggregates = {
  totalTvl: number
  weightedApy: number
  weightedUtilization: number
  activeMarkets: number
  weightedChange24h: number
}

function parseMarketUsd(value: string) {
  const normalized = value.trim().replace(/[$,]/g, "")
  const suffix = normalized.slice(-1).toUpperCase()
  const numericPortion = suffix >= "A" && suffix <= "Z" ? normalized.slice(0, -1) : normalized
  const amount = Number.parseFloat(numericPortion)
  if (!Number.isFinite(amount)) return 0
  if (suffix === "B") return amount * 1_000_000_000
  if (suffix === "M") return amount * 1_000_000
  if (suffix === "K") return amount * 1_000
  return amount
}

export function aggregateLendHeroFromMarkets(markets: ReadonlyArray<LendHeroMarketInput>): LendHeroAggregates {
  const activeMarkets = markets.filter((market) => !market.soon)
  const marketValues = activeMarkets.map((market) => ({
    ...market,
    tvlUsd: market.tvlUsd ?? parseMarketUsd(market.tvl ?? "0"),
  }))
  const totalTvl = marketValues.reduce((sum, market) => sum + market.tvlUsd, 0)
  const weightedApy =
    totalTvl > 0 ? marketValues.reduce((sum, market) => sum + market.apy * market.tvlUsd, 0) / totalTvl : 0
  const weightedUtilization =
    totalTvl > 0 ? marketValues.reduce((sum, market) => sum + market.utilization * market.tvlUsd, 0) / totalTvl : 0
  const weightedChange24h =
    totalTvl > 0
      ? marketValues.reduce((sum, market) => sum + (market.apyChange24h ?? 0) * market.tvlUsd, 0) / totalTvl
      : 0

  return {
    totalTvl,
    weightedApy,
    weightedUtilization,
    activeMarkets: activeMarkets.length,
    weightedChange24h,
  }
}
