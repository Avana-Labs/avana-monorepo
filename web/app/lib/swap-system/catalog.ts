import { sandboxBaselinePriceUsd } from "@/app/lib/prices/sandbox-baseline-prices"
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
    priceUsd: sandboxBaselinePriceUsd("ETH"),
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
    priceUsd: sandboxBaselinePriceUsd("USDC"),
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
    priceUsd: sandboxBaselinePriceUsd("GHO"),
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
    // Aligned with the single sandbox baseline (see prices/sandbox-baseline-prices.ts).
    priceUsd: sandboxBaselinePriceUsd("WBTC"),
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
    priceUsd: sandboxBaselinePriceUsd("LINK"),
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
    // Aligned with the single sandbox baseline (see prices/sandbox-baseline-prices.ts).
    priceUsd: sandboxBaselinePriceUsd("AAVE"),
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
    priceUsd: sandboxBaselinePriceUsd("USDT"),
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
    // Aligned with the single sandbox baseline (WETH tracks ETH — see prices/sandbox-baseline-prices.ts).
    priceUsd: sandboxBaselinePriceUsd("WETH"),
    minimumSwapAmount: 0.00001,
    maximumSwapAmount: 500,
  },
  {
    // Multiply collateral (see multiply-system/catalog markets crv-crvusd, crvusd-usdt), surfaced in
    // the dashboard "Available to loop" card. Metadata-only so the row resolves a real name/icon/price
    // instead of "Unsupported asset"; not swap-routed (isSwapEnabled: false → adds no SWAP_PAIRS).
    id: "crvusd",
    chainId: SWAP_CHAIN_ID,
    symbol: "crvUSD",
    name: "Curve USD",
    decimals: 18,
    assetType: "erc20",
    isNative: false,
    isLpToken: false,
    isSwapEnabled: false,
    priceUsd: sandboxBaselinePriceUsd("CRVUSD"),
    minimumSwapAmount: 0,
    maximumSwapAmount: 0,
  },
  {
    // Multiply collateral surfaced by the wallet/product balance feed. Metadata-only so it
    // resolves correctly in shared dashboard tables without making WSTETH a swap route.
    id: "wsteth",
    chainId: SWAP_CHAIN_ID,
    symbol: "WSTETH",
    name: "Wrapped stETH",
    decimals: 18,
    assetType: "erc20",
    isNative: false,
    isLpToken: false,
    isSwapEnabled: false,
    priceUsd: sandboxBaselinePriceUsd("WSTETH"),
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
