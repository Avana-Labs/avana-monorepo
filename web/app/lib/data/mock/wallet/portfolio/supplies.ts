import type { PortfolioSupplyRecord } from "@/app/lib/data/providers/portfolio/source"

const WALLET_SUPPLIES: PortfolioSupplyRecord[] = [
  {
    id: "supply-dai",
    walletProfileId: "demo-wallet",
    symbol: "DAI",
    name: "Dai Stablecoin",
    balance: 34_600,
    priceUsd: 1,
    suppliedUsd: 34_600,
    earnedUsd: 1_420,
    dailyEarnedUsd: 9.64,
    apyPct: 4.84,
  },
  {
    id: "supply-usdc",
    walletProfileId: "demo-wallet",
    symbol: "USDC",
    name: "USD Coin",
    balance: 28_200,
    priceUsd: 1,
    suppliedUsd: 28_200,
    earnedUsd: 1_860,
    dailyEarnedUsd: 12.43,
    apyPct: 5.12,
  },
  {
    id: "supply-usdt",
    walletProfileId: "demo-wallet",
    symbol: "USDT",
    name: "Tether USD",
    balance: 15_400,
    priceUsd: 1,
    suppliedUsd: 15_400,
    earnedUsd: 610,
    dailyEarnedUsd: 4.18,
    apyPct: 4.42,
  },
]

export function getWalletSupplies(walletProfileId: string) {
  return WALLET_SUPPLIES.filter((record) => record.walletProfileId === walletProfileId)
}
