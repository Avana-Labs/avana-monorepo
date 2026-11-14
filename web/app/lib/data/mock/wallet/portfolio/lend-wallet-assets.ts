type WalletLendAssetRecord = {
  walletProfileId: string
  symbol: string
  name: string
  balance: number
  price: number
  color: string
  bg: string
  apy: number
  earned: number
  daily: number
  utilization: number
}

const WALLET_LEND_ASSETS: WalletLendAssetRecord[] = [
  {
    walletProfileId: "demo-wallet",
    symbol: "USDC",
    name: "USD Coin",
    balance: 8200.0,
    price: 1.0,
    color: "text-[#2775CA]",
    bg: "bg-[#EBF5FF]",
    apy: 5.2,
    earned: 344.4,
    daily: 12.4,
    utilization: 68,
  },
  {
    walletProfileId: "demo-wallet",
    symbol: "ETH",
    name: "Ethereum",
    balance: 1.28,
    price: 3281.25,
    color: "text-[#627EEA]",
    bg: "bg-[#EEF0FF]",
    apy: 3.82,
    earned: 153.8,
    daily: 4.4,
    utilization: 54,
  },
  {
    walletProfileId: "demo-wallet",
    symbol: "USDT",
    name: "Tether USD",
    balance: 2000.0,
    price: 1.0,
    color: "text-[#26A17B]",
    bg: "bg-[#E8FAF0]",
    apy: 4.8,
    earned: 0.0,
    daily: 0.26,
    utilization: 31,
  },
]

export function getWalletLendAssets(walletProfileId: string) {
  const assets = WALLET_LEND_ASSETS.filter((record) => record.walletProfileId === walletProfileId)
  return assets.length > 0 ? assets : WALLET_LEND_ASSETS.filter((record) => record.walletProfileId === "demo-wallet")
}
