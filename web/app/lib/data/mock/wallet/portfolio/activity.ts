import type { PortfolioActivityRecord } from "@/app/lib/data/providers/portfolio/source"

type WalletActivitySeed = Omit<PortfolioActivityRecord, "id" | "walletProfileId" | "at" | "txHash">

const ACTIVITY_SEEDS: Array<WalletActivitySeed & { minutesAgo: number }> = [
  {
    minutesAgo: 1,
    product: "pool",
    kind: "pledge",
    status: "confirmed",
    amountUsd: 42_200,
    primaryLabel: "WETH / USDC",
    secondaryLabel: "Uniswap v3 Bluechip collateral",
  },
  {
    minutesAgo: 4,
    product: "multiply",
    kind: "addCollateral",
    status: "pending",
    amountUsd: 8_400,
    primaryLabel: "ETH Loop",
    secondaryLabel: "Added collateral to 4.0x long",
  },
  {
    minutesAgo: 8,
    product: "lend",
    kind: "supply",
    status: "confirmed",
    amountUsd: 34_600,
    primaryLabel: "DAI",
    secondaryLabel: "Supply market deposit",
  },
  {
    minutesAgo: 12,
    product: "borrow",
    kind: "borrow",
    status: "confirmed",
    amountUsd: -12_400,
    primaryLabel: "USDC",
    secondaryLabel: "Borrowed against LP collateral",
  },
  {
    minutesAgo: 19,
    product: "pool",
    kind: "claim",
    status: "confirmed",
    amountUsd: 6_400,
    primaryLabel: "wstETH / WETH",
    secondaryLabel: "Claimed collateral incentives",
  },
  {
    minutesAgo: 27,
    product: "multiply",
    kind: "rebalance",
    status: "confirmed",
    amountUsd: 9_800,
    primaryLabel: "cbBTC Basis",
    secondaryLabel: "Range rebalance executed",
  },
  {
    minutesAgo: 35,
    product: "lend",
    kind: "withdraw",
    status: "pending",
    amountUsd: -15_400,
    primaryLabel: "USDT",
    secondaryLabel: "Yield withdrawal requested",
  },
  {
    minutesAgo: 43,
    product: "borrow",
    kind: "repay",
    status: "confirmed",
    amountUsd: 8_100,
    primaryLabel: "DAI",
    secondaryLabel: "Debt repayment",
  },
  {
    minutesAgo: 58,
    product: "pool",
    kind: "pledge",
    status: "confirmed",
    amountUsd: 26_800,
    primaryLabel: "WBTC / WETH",
    secondaryLabel: "Aerodrome LP pledged",
  },
  {
    minutesAgo: 76,
    product: "multiply",
    kind: "open",
    status: "confirmed",
    amountUsd: 33_600,
    primaryLabel: "SOL Momentum",
    secondaryLabel: "Opened 3.0x multiply position",
  },
  {
    minutesAgo: 92,
    product: "lend",
    kind: "interest",
    status: "confirmed",
    amountUsd: 1_900,
    primaryLabel: "USDC",
    secondaryLabel: "Interest settled to wallet",
  },
  {
    minutesAgo: 118,
    product: "borrow",
    kind: "withdraw",
    status: "failed",
    amountUsd: -4_800,
    primaryLabel: "crvUSD",
    secondaryLabel: "Borrow market withdrawal reverted",
  },
  {
    minutesAgo: 155,
    product: "pool",
    kind: "claim",
    status: "confirmed",
    amountUsd: 1_300,
    primaryLabel: "cbBTC / WETH",
    secondaryLabel: "Fee claim settled",
  },
  {
    minutesAgo: 188,
    product: "multiply",
    kind: "reduce",
    status: "confirmed",
    amountUsd: -11_200,
    primaryLabel: "ETH Loop",
    secondaryLabel: "Reduced collateral exposure",
  },
  {
    minutesAgo: 240,
    product: "lend",
    kind: "supply",
    status: "confirmed",
    amountUsd: 19_400,
    primaryLabel: "USDC",
    secondaryLabel: "Supply market deposit",
  },
  {
    minutesAgo: 318,
    product: "borrow",
    kind: "liquidation",
    status: "confirmed",
    amountUsd: 3_600,
    primaryLabel: "WETH / USDT",
    secondaryLabel: "Liquidation incentive received",
  },
  {
    minutesAgo: 402,
    product: "pool",
    kind: "pledge",
    status: "pending",
    amountUsd: 14_300,
    primaryLabel: "USDC / USDT",
    secondaryLabel: "LP collateral transfer pending",
  },
  {
    minutesAgo: 525,
    product: "multiply",
    kind: "close",
    status: "confirmed",
    amountUsd: -22_500,
    primaryLabel: "ARB Carry",
    secondaryLabel: "Position closed and debt settled",
  },
]

function hashString(input: string): number {
  let hash = 2166136261
  for (let index = 0; index < input.length; index += 1) {
    hash ^= input.charCodeAt(index)
    hash = Math.imul(hash, 16777619)
  }
  return Math.abs(hash)
}

// These are simulated sandbox rows, not real on-chain transactions, so the hash
// must NOT look like a canonical 0x+64hex hash — otherwise RecentActivity routes
// it to Etherscan and produces a dead link. A "sim-" prefix keeps the value
// deterministic per wallet/index while signalling it belongs to the in-app receipt.
function buildTxHash(seed: number, index: number) {
  let value = seed + index * 7919
  let hash = "sim-"
  for (let position = 0; position < 40; position += 1) {
    value = Math.imul(value ^ (value >>> 13), 1274126177)
    hash += ((value >>> 28) & 0xf).toString(16)
  }
  return hash
}

export function getWalletActivity(walletProfileId: string) {
  const walletSeed = hashString(walletProfileId.toLowerCase())
  const now = Date.now()

  return ACTIVITY_SEEDS.map((seed, index) => {
    const txHash = buildTxHash(walletSeed, index)
    return {
      id: `${walletProfileId}-${index}`,
      walletProfileId,
      at: new Date(now - seed.minutesAgo * 60_000).toISOString(),
      product: seed.product,
      kind: seed.kind,
      status: seed.status,
      amountUsd: seed.amountUsd,
      primaryLabel: seed.primaryLabel,
      secondaryLabel: seed.secondaryLabel,
      txHash,
    }
  })
}
