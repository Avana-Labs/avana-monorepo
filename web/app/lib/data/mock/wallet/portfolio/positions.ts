import type {
  PortfolioCollateralRecord,
  PortfolioCreditLinesRecord,
  PortfolioMultiplyCollateralRecord,
  PortfolioMultiplyPositionRecord,
  PortfolioOpenOrderRecord,
  PortfolioPoolRecord,
  PortfolioTwapOrderRecord,
} from "@/app/lib/data/providers/portfolio/source"

const ETH_USDC_POOL: PortfolioPoolRecord = {
  id: "uni-v3-bluechip-weth-usdc",
  name: "WETH / USDC",
  venue: "Uniswap v3 Bluechip",
  category: "v3",
  collateralUsd: 42_200,
  maxLtv: 76.5,
  borrowPowerUsd: 32_300,
  liquidationUsd: 30_100,
  pairApr: 5.3,
  visuals: [
    {
      symbol: "WETH",
      shortLabel: "W",
      bgClassName: "bg-sky-500",
      textClassName: "text-white",
    },
    {
      symbol: "USDC",
      shortLabel: "U",
      bgClassName: "bg-cyan-500",
      textClassName: "text-white",
    },
  ],
}

const WBTC_WETH_POOL: PortfolioPoolRecord = {
  id: "aerodrome-wbtc-weth",
  name: "WBTC / WETH",
  venue: "Aerodrome",
  category: "v3",
  collateralUsd: 26_800,
  maxLtv: 74.2,
  borrowPowerUsd: 19_900,
  liquidationUsd: 19_500,
  pairApr: 4.9,
  visuals: [
    {
      symbol: "WBTC",
      shortLabel: "B",
      bgClassName: "bg-amber-500",
      textClassName: "text-white",
    },
    {
      symbol: "WETH",
      shortLabel: "W",
      bgClassName: "bg-sky-500",
      textClassName: "text-white",
    },
  ],
}

const USDC_USDT_POOL: PortfolioPoolRecord = {
  id: "curve-usdc-usdt",
  name: "USDC / USDT",
  venue: "Curve",
  category: "stable",
  collateralUsd: 18_900,
  maxLtv: 82,
  borrowPowerUsd: 15_500,
  liquidationUsd: 14_800,
  pairApr: 3.1,
  visuals: [
    {
      symbol: "USDC",
      shortLabel: "U",
      bgClassName: "bg-cyan-500",
      textClassName: "text-white",
    },
    {
      symbol: "USDT",
      shortLabel: "T",
      bgClassName: "bg-amber-500",
      textClassName: "text-white",
    },
  ],
}

const WALLET_COLLATERALS: PortfolioCollateralRecord[] = [
  {
    id: "collateral-eth-usdc",
    walletProfileId: "demo-wallet",
    pool: ETH_USDC_POOL,
    borrowedUsd: 12_400,
    healthFactor: 2.6,
    pairApr: 5.3,
    feesUsd: 418,
  },
  {
    id: "collateral-wbtc-weth",
    walletProfileId: "demo-wallet",
    pool: WBTC_WETH_POOL,
    borrowedUsd: 8_800,
    healthFactor: 2.26,
    pairApr: 4.9,
    feesUsd: 612,
  },
  {
    id: "collateral-usdc-usdt",
    walletProfileId: "demo-wallet",
    pool: USDC_USDT_POOL,
    borrowedUsd: 6_200,
    healthFactor: 2.5,
    pairApr: 3.1,
    feesUsd: 186,
  },
]

const WALLET_MULTIPLY_POSITIONS: PortfolioMultiplyPositionRecord[] = [
  {
    id: "mult-eth-loop",
    walletProfileId: "demo-wallet",
    symbol: "ETH",
    label: "ETH Loop",
    side: "long",
    leverage: 4,
    collateralUsd: 8_400,
    exposureUsd: 33_600,
    pnlUsd: 720,
    pnlPct: 8.57,
    status: "open",
  },
  {
    id: "mult-sol-momentum",
    walletProfileId: "demo-wallet",
    symbol: "SOL",
    label: "SOL Momentum",
    side: "long",
    leverage: 3,
    collateralUsd: 11_500,
    exposureUsd: 34_500,
    pnlUsd: 1_140,
    pnlPct: 9.91,
    status: "open",
  },
  {
    id: "mult-arb-carry",
    walletProfileId: "demo-wallet",
    symbol: "ARB",
    label: "ARB Carry",
    side: "short",
    leverage: 2,
    collateralUsd: 6_200,
    exposureUsd: 12_400,
    pnlUsd: -410,
    pnlPct: -6.61,
    status: "closed",
  },
]

const WALLET_MULTIPLY_CREDIT_LINES: PortfolioCreditLinesRecord[] = [
  {
    walletProfileId: "demo-wallet",
    approvedUsd: 64_400,
    liquidationThresholdUsd: 72_957,
    averageHealthFactor: 2.45,
    currentLtvPct: 31.17,
    totalBorrowedUsd: 27_400,
    totalCollateralUsd: 87_900,
  },
]

const WALLET_MULTIPLY_COLLATERALS: PortfolioMultiplyCollateralRecord[] = [
  {
    id: "mult-collateral-weth-usdc",
    walletProfileId: "demo-wallet",
    label: "WETH / USDC",
    collateralToken: "WETH",
    borrowableToken: "USDC",
    multiplier: 4,
    protocol: "Uniswap v3 Bluechip",
    healthFactor: 2.6,
    collateralUsd: 36_000,
    borrowPowerUsd: 27_800,
  },
  {
    id: "mult-collateral-wbtc-weth",
    walletProfileId: "demo-wallet",
    label: "WBTC / WETH",
    collateralToken: "WBTC",
    borrowableToken: "WETH",
    multiplier: 3,
    protocol: "Aerodrome",
    healthFactor: 2.18,
    collateralUsd: 29_400,
    borrowPowerUsd: 20_900,
  },
  {
    id: "mult-collateral-usdc-usdt",
    walletProfileId: "demo-wallet",
    label: "USDC / USDT",
    collateralToken: "USDC",
    borrowableToken: "USDT",
    multiplier: 2,
    protocol: "Curve",
    healthFactor: 2.49,
    collateralUsd: 22_500,
    borrowPowerUsd: 15_700,
  },
]

const WALLET_OPEN_ORDERS: PortfolioOpenOrderRecord[] = [
  {
    id: "open-1",
    walletProfileId: "demo-wallet",
    label: "USDC ladder",
    status: "open",
    sizeUsd: 16_200,
    venue: "Uniswap v3",
  },
  {
    id: "open-2",
    walletProfileId: "demo-wallet",
    label: "ETH range",
    status: "pending",
    sizeUsd: 9_400,
    venue: "Aerodrome",
  },
]

const WALLET_TWAP_ORDERS: PortfolioTwapOrderRecord[] = [
  {
    id: "twap-1",
    walletProfileId: "demo-wallet",
    label: "DAI roll",
    interval: "4h",
    status: "active",
    amountUsd: 24_000,
  },
]

export function getWalletCollaterals(walletProfileId: string) {
  return WALLET_COLLATERALS.filter((record) => record.walletProfileId === walletProfileId)
}

export function getWalletMultiplyPositions(walletProfileId: string) {
  return WALLET_MULTIPLY_POSITIONS.filter((record) => record.walletProfileId === walletProfileId)
}

export function getWalletMultiplyCreditLines(walletProfileId: string) {
  return (
    WALLET_MULTIPLY_CREDIT_LINES.find((record) => record.walletProfileId === walletProfileId) ??
    WALLET_MULTIPLY_CREDIT_LINES[0]
  )
}

export function getWalletMultiplyCollaterals(walletProfileId: string) {
  return WALLET_MULTIPLY_COLLATERALS.filter((record) => record.walletProfileId === walletProfileId)
}

export function getWalletOpenOrders(walletProfileId: string) {
  return WALLET_OPEN_ORDERS.filter((record) => record.walletProfileId === walletProfileId)
}

export function getWalletTwapOrders(walletProfileId: string) {
  return WALLET_TWAP_ORDERS.filter((record) => record.walletProfileId === walletProfileId)
}
