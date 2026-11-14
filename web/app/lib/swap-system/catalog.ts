import type { SwapAsset, SwapPair } from "./contracts"

export const SWAP_CHAIN_ID = 1
export const NATIVE_GAS_RESERVE_ETH = 0.002

export const SWAP_ASSETS: SwapAsset[] = [
  {
    id: "eth",
    chainId: SWAP_CHAIN_ID,
    symbol: "ETH",
    name: "Ether",
    decimals: 18,
    assetType: "native",
    isNative: true,
    isLpToken: false,
    isSwapEnabled: true,
    priceUsd: 0,
    minimumSwapAmount: 0.00001,
    maximumSwapAmount: 500,
  },
  {
    id: "usdc",
    chainId: SWAP_CHAIN_ID,
    symbol: "USDC",
    name: "USD Coin",
    decimals: 6,
    assetType: "erc20",
    isNative: false,
    isLpToken: false,
    isSwapEnabled: true,
    priceUsd: 0,
    minimumSwapAmount: 1,
    maximumSwapAmount: 1_000_000,
  },
  {
    id: "gho",
    chainId: SWAP_CHAIN_ID,
    symbol: "GHO",
    name: "GHO",
    decimals: 18,
    assetType: "erc20",
    isNative: false,
    isLpToken: false,
    isSwapEnabled: true,
    priceUsd: 0,
    minimumSwapAmount: 1,
    maximumSwapAmount: 1_000_000,
  },
  {
    id: "wbtc",
    chainId: SWAP_CHAIN_ID,
    symbol: "WBTC",
    name: "Wrapped Bitcoin",
    decimals: 8,
    assetType: "erc20",
    isNative: false,
    isLpToken: false,
    isSwapEnabled: true,
    // Display price comes from the live price layer; 0 means none.
    priceUsd: 0,
    minimumSwapAmount: 0.00001,
    maximumSwapAmount: 50,
  },
  {
    id: "link",
    chainId: SWAP_CHAIN_ID,
    symbol: "LINK",
    name: "ChainLink Token",
    decimals: 18,
    assetType: "erc20",
    isNative: false,
    isLpToken: false,
    isSwapEnabled: true,
    priceUsd: 0,
    minimumSwapAmount: 0.01,
    maximumSwapAmount: 500_000,
  },
  {
    id: "aave",
    chainId: SWAP_CHAIN_ID,
    symbol: "AAVE",
    name: "Aave Token",
    decimals: 18,
    assetType: "erc20",
    isNative: false,
    isLpToken: false,
    isSwapEnabled: true,
    // Display price comes from the live price layer; 0 means none.
    priceUsd: 0,
    minimumSwapAmount: 0.001,
    maximumSwapAmount: 100_000,
  },
  {
    id: "usdt",
    chainId: SWAP_CHAIN_ID,
    symbol: "USDT",
    name: "Tether USD",
    decimals: 6,
    assetType: "erc20",
    isNative: false,
    isLpToken: false,
    isSwapEnabled: true,
    priceUsd: 0,
    minimumSwapAmount: 1,
    maximumSwapAmount: 1_000_000,
  },
  {
    id: "weth",
    chainId: SWAP_CHAIN_ID,
    symbol: "WETH",
    name: "Wrapped Ether",
    decimals: 18,
    assetType: "erc20",
    isNative: false,
    isLpToken: false,
    isSwapEnabled: true,
    priceUsd: 0,
    minimumSwapAmount: 0.00001,
    maximumSwapAmount: 500,
  },
  {
    // Collateral surfaced by the wallet/product balance feed. Metadata-only so it resolves
    // correctly in shared dashboard tables without making WSTETH a swap route.
    id: "wsteth",
    chainId: SWAP_CHAIN_ID,
    symbol: "WSTETH",
    name: "Wrapped stETH",
    decimals: 18,
    assetType: "erc20",
    isNative: false,
    isLpToken: false,
    isSwapEnabled: false,
    priceUsd: 0,
    minimumSwapAmount: 0,
    maximumSwapAmount: 0,
  },
  {
    id: "eth-usdc-lp",
    chainId: SWAP_CHAIN_ID,
    symbol: "ETH/USDC LP",
    name: "ETH / USDC LP",
    decimals: 18,
    assetType: "lp_token",
    isNative: false,
    isLpToken: true,
    isSwapEnabled: false,
    priceUsd: 125,
    minimumSwapAmount: 0,
    maximumSwapAmount: 0,
    lpUnderlyingSymbols: ["ETH", "USDC"],
  },
]

const ROUTED_ASSET_IDS = SWAP_ASSETS.filter((asset) => asset.isSwapEnabled && !asset.isLpToken).map((asset) => asset.id)

export const SWAP_PAIRS: SwapPair[] = ROUTED_ASSET_IDS.flatMap((inputAssetId) =>
  ROUTED_ASSET_IDS.filter((outputAssetId) => outputAssetId !== inputAssetId).map((outputAssetId) => ({
    id: `${inputAssetId}-${outputAssetId}`,
    chainId: SWAP_CHAIN_ID,
    inputAssetId,
    outputAssetId,
    isEnabled: true,
    provider: "Avana mock router",
    feeBps: 30,
  })),
)

export function getSwapAsset(assetId: string) {
  const normalized = assetId.trim().toLowerCase()
  return SWAP_ASSETS.find((asset) => asset.id.toLowerCase() === normalized)
}

export function getSwapPair(inputAssetId: string, outputAssetId: string, chainId = SWAP_CHAIN_ID) {
  return SWAP_PAIRS.find(
    (pair) => pair.chainId === chainId && pair.inputAssetId === inputAssetId && pair.outputAssetId === outputAssetId,
  )
}
