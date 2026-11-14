import type { PortfolioStrategyBucketRecord } from "@/app/lib/data/providers/portfolio/source"

export const WALLET_STRATEGY_BUCKETS: PortfolioStrategyBucketRecord[] = [
  {
    title: "Conservative Strategy",
    description: "Stable assets with lower risk",
    apyRangeLabel: "4-8% APY range",
    tone: "conservative",
    pools: [
      { name: "Uniswap USDC-USDT", apyPct: 4.2, tvlUsd: 88_400, isUp: true, allocationUsd: 18_400 },
      { name: "Aave USDC", apyPct: 5.1, tvlUsd: 76_200, isUp: true, allocationUsd: 24_100 },
      { name: "Convex USDT", apyPct: 6.3, tvlUsd: 41_900, isUp: true, allocationUsd: 11_200 },
      { name: "Chainlink USDC", apyPct: 7.2, tvlUsd: 28_500, isUp: false, allocationUsd: 6_800 },
    ],
  },
  {
    title: "Moderate Strategy",
    description: "Balanced risk-reward ratio",
    apyRangeLabel: "8-15% APY range",
    tone: "moderate",
    pools: [
      { name: "Compound ETH-USDC", apyPct: 12.5, tvlUsd: 91_200, isUp: true, allocationUsd: 31_800 },
      { name: "Rocket Pool stETH", apyPct: 9.8, tvlUsd: 64_700, isUp: true, allocationUsd: 15_300 },
      { name: "Balancer ETH-DAI", apyPct: 14.2, tvlUsd: 53_800, isUp: false, allocationUsd: 8_400 },
      { name: "Solana USDC", apyPct: 11.5, tvlUsd: 72_100, isUp: true, allocationUsd: 13_700 },
    ],
  },
  {
    title: "Aggressive Strategy",
    description: "High risk, high potential returns",
    apyRangeLabel: "15-40% APY range",
    tone: "aggressive",
    pools: [
      { name: "Curve ETH-BTC", apyPct: 35.8, tvlUsd: 39_600, isUp: true, allocationUsd: 3_200 },
      { name: "Balancer WETH-DAI", apyPct: 28.4, tvlUsd: 31_800, isUp: false, allocationUsd: 2_400 },
      { name: "Pancakeswap BNB-USDT", apyPct: 42.1, tvlUsd: 27_400, isUp: true, allocationUsd: 1_500 },
      { name: "Sushiswap ETH-USDC", apyPct: 31.6, tvlUsd: 44_100, isUp: false, allocationUsd: 2_800 },
    ],
  },
]
