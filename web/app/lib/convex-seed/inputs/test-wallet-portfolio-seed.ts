// SEED ONLY — imported by build-seed.ts. Not for UI code. Rows key against TEST_WALLET_ADDRESS so dev sessions gated through the test-wallet gate render populated portfolio cards.

import type { SeedWalletCollateralPositionRow, SeedWalletDebtRow, SeedWalletClaimPositionRow } from "../build-seed"
import { TEST_WALLET_ADDRESS } from "../test-wallet"

export const TEST_WALLET_COLLATERAL_SEED_ROWS: SeedWalletCollateralPositionRow[] = [
  {
    wallet: TEST_WALLET_ADDRESS,
    homePoolId: "eth-usdc",
    marketId: "uni-v3-bluechip-weth-usdc",
    name: "ETH / USDC",
    venueLabel: "Uni v3 Bluechip",
    category: "Bluechip Spoke",
    collateralUsd: 4_200,
    maxLtvPct: 70,
    borrowPowerUsd: 2_940,
    liquidationUsd: 3_380,
    pairAprPct: 8.7,
  },
  {
    wallet: TEST_WALLET_ADDRESS,
    homePoolId: "wbtc-eth",
    marketId: "uni-v3-bluechip-wbtc-weth",
    name: "WBTC / ETH",
    venueLabel: "Uni v3 Bluechip",
    category: "Bluechip Spoke",
    collateralUsd: 2_100,
    maxLtvPct: 67,
    borrowPowerUsd: 1_407,
    liquidationUsd: 1_700,
    pairAprPct: 6.2,
  },
  {
    wallet: TEST_WALLET_ADDRESS,
    homePoolId: "usdc-usdt",
    marketId: "uni-v3-stable-usdc-usdt",
    name: "USDC / USDT",
    venueLabel: "Uni v3 Stable",
    category: "Stable Spoke",
    collateralUsd: 8_100,
    maxLtvPct: 78,
    borrowPowerUsd: 6_318,
    liquidationUsd: 6_560,
    pairAprPct: 3.2,
  },
]

export const TEST_WALLET_DEBTS_SEED_ROWS: SeedWalletDebtRow[] = [
  {
    wallet: TEST_WALLET_ADDRESS,
    homePoolId: "eth-usdc",
    marketId: "uni-v3-bluechip-weth-usdc",
    debtAssetId: "usdc",
    amountUsd: 1_200,
  },
  {
    wallet: TEST_WALLET_ADDRESS,
    homePoolId: "usdc-usdt",
    marketId: "uni-v3-stable-usdc-usdt",
    debtAssetId: "usdt",
    amountUsd: 800,
  },
]

export const TEST_WALLET_CLAIMS_SEED_ROWS: SeedWalletClaimPositionRow[] = [
  {
    wallet: TEST_WALLET_ADDRESS,
    claimId: "claim-eth-usdc",
    homePoolId: "eth-usdc",
    marketId: "uni-v3-bluechip-weth-usdc",
    name: "ETH / USDC",
    subtitle: "Uni v3 · Bluechip · 0.3%",
    totalUsd: 111.1,
    breakdown: [
      {
        symbol: "ETH",
        amountLabel: "0.0210 ETH",
        amountToken: 0.021,
        usdValue: 68.99,
        visualSymbol: "ETH",
      },
      {
        symbol: "USDC",
        amountLabel: "42.11 USDC",
        amountToken: 42.11,
        usdValue: 42.11,
        visualSymbol: "USDC",
      },
    ],
  },
  {
    wallet: TEST_WALLET_ADDRESS,
    claimId: "claim-usdc-usdt",
    homePoolId: "usdc-usdt",
    marketId: "uni-v3-stable-usdc-usdt",
    name: "USDC / USDT",
    subtitle: "Uni v3 · Stable · 0.01%",
    totalUsd: 62.4,
    breakdown: [
      {
        symbol: "USDC",
        amountLabel: "42.11 USDC",
        amountToken: 42.11,
        usdValue: 42.11,
        visualSymbol: "USDC",
      },
      {
        symbol: "USDT",
        amountLabel: "20.29 USDT",
        amountToken: 20.29,
        usdValue: 20.29,
        visualSymbol: "USDT",
      },
    ],
  },
  {
    wallet: TEST_WALLET_ADDRESS,
    claimId: "claim-wbtc-eth",
    homePoolId: "wbtc-eth",
    marketId: "uni-v3-bluechip-wbtc-weth",
    name: "WBTC / ETH",
    subtitle: "Uni v3 · Bluechip · 0.3%",
    totalUsd: 79.6,
    breakdown: [
      {
        symbol: "WBTC",
        amountLabel: "0.0011 WBTC",
        amountToken: 0.0011,
        usdValue: 48.1,
        visualSymbol: "WBTC",
      },
      {
        symbol: "ETH",
        amountLabel: "0.0094 ETH",
        amountToken: 0.0094,
        usdValue: 31.5,
        visualSymbol: "ETH",
      },
    ],
  },
]
