import { getActiveCurrency } from "@/app/lib/currency/active-rate"
import { healthFactorBand } from "@/app/lib/health/health-factor-bands"

export type HomeMode = "borrow" | "swap" | "repay" | "claim" | "remove"

export type HomeAssetVisual = {
  symbol: string
  shortLabel: string
  bgClassName: string
  textClassName: string
}

export type HomeCollateralPool = {
  id: string
  name: string
  venue: string
  category: string
  collateralUsd: number
  /** This pool's own pledged LP; `collateralUsd` is the credit shared across its group. */
  ownCollateralUsd?: number
  maxLtv: number
  borrowPowerUsd: number
  liquidationUsd: number
  pairApr: number
  visuals: [HomeAssetVisual, HomeAssetVisual]
}

export type HomeBorrowToken = {
  id: string
  name: string
  symbol: string
  subtitle: string
  borrowApr: number
  visual: HomeAssetVisual
}

export type HomeClaimBreakdown = {
  id: string
  symbol: string
  amountLabel: string
  usdValue: number
  visual: HomeAssetVisual
}

export type HomeClaimPosition = {
  id: string
  poolId: string
  name: string
  subtitle: string
  totalUsd: number
  breakdown: HomeClaimBreakdown[]
}

export type HomeSuccessRowTone = "default" | "positive" | "warning" | "danger"

export type HomeSuccessRow = {
  label: string
  value: string
  tone?: HomeSuccessRowTone
}

export type HomeRiskTone = "neutral" | "positive" | "warning" | "danger"

export type BorrowPreview = {
  amountUsd: number
  amountLabel: string
  isEmpty: boolean
  isValid: boolean
  exceedsBorrowPower: boolean
  healthFactor: number | null
  healthFactorLabel: string
  riskTone: HomeRiskTone
  progressPercent: number
  remainingBorrowPowerUsd: number
  warningTitle: string | null
  warningMessage: string | null
  ctaLabel: string
}

export type RepayPreview = {
  amountUsd: number
  isEmpty: boolean
  isValid: boolean
  exceedsDebt: boolean
  remainingDebtUsd: number
  remainingDebtLabel: string
  healthFactorAfter: number | null
  healthFactorAfterLabel: string
  oldHealthFactorLabel: string
  riskTone: HomeRiskTone
  yearlyInterestSavedUsd: number
  ctaLabel: string
}

export type ClaimPreview = {
  selectedPositionIds: string[]
  selectedTotalUsd: number
  effectiveClaimUsd: number
  hasSelection: boolean
  hasCustomAmount: boolean
  ctaLabel: string
  helperLabel: string
  tokenTotals: Record<string, number>
}

export type RemovePreview = {
  percent: number
  safePercent: number
  removeUsd: number
  afterCollateralUsd: number
  healthFactorAfter: number | null
  healthFactorAfterLabel: string
  riskTone: HomeRiskTone
  isUnsafe: boolean
  isValid: boolean
  liquidationThresholdAfterUsd: number
  ctaLabel: string
}

export const HOME_PORTFOLIO_SUMMARY = {
  totalCollateralUsd: 14_400,
  dailyChangeUsd: 340,
  borrowedUsd: 1_200,
  availableUsd: 8_880,
  averageHealthFactor: 2.3,
  chartSeed: "lpfi-home-root",
}

export const HOME_COLLATERAL_POOLS: HomeCollateralPool[] = [
  {
    id: "eth-usdc",
    name: "ETH / USDC",
    venue: "Uni v3 Bluechip",
    category: "Bluechip Spoke",
    collateralUsd: 4_200,
    maxLtv: 70,
    borrowPowerUsd: 2_940,
    liquidationUsd: 3_380,
    pairApr: 8.7,
    visuals: [
      { symbol: "ETH", shortLabel: "ETH", bgClassName: "bg-indigo-100", textClassName: "text-indigo-600" },
      { symbol: "USDC", shortLabel: "U", bgClassName: "bg-sky-100", textClassName: "text-sky-700" },
    ],
  },
  {
    id: "wbtc-eth",
    name: "WBTC / ETH",
    venue: "Uni v3 Bluechip",
    category: "Bluechip Spoke",
    collateralUsd: 2_100,
    maxLtv: 67,
    borrowPowerUsd: 1_407,
    liquidationUsd: 1_700,
    pairApr: 6.2,
    visuals: [
      { symbol: "WBTC", shortLabel: "BTC", bgClassName: "bg-amber-100", textClassName: "text-amber-700" },
      { symbol: "ETH", shortLabel: "ETH", bgClassName: "bg-indigo-100", textClassName: "text-indigo-600" },
    ],
  },
  {
    id: "usdc-usdt",
    name: "USDC / USDT",
    venue: "Uni v3 Stable",
    category: "Stable Spoke",
    collateralUsd: 8_100,
    maxLtv: 78,
    borrowPowerUsd: 6_318,
    liquidationUsd: 6_560,
    pairApr: 3.2,
    visuals: [
      { symbol: "USDC", shortLabel: "U", bgClassName: "bg-sky-100", textClassName: "text-sky-700" },
      { symbol: "USDT", shortLabel: "T", bgClassName: "bg-emerald-100", textClassName: "text-emerald-700" },
    ],
  },
]

export const HOME_BORROW_TOKENS: HomeBorrowToken[] = [
  {
    id: "eth",
    name: "Ethereum",
    symbol: "ETH",
    subtitle: "Native asset",
    borrowApr: 4.1,
    visual: { symbol: "ETH", shortLabel: "ETH", bgClassName: "bg-indigo-100", textClassName: "text-indigo-600" },
  },
  {
    id: "usdc",
    name: "USD Coin",
    symbol: "USDC",
    subtitle: "Stablecoin",
    borrowApr: 5.2,
    visual: { symbol: "USDC", shortLabel: "U", bgClassName: "bg-sky-100", textClassName: "text-sky-700" },
  },
  {
    id: "usdt",
    name: "Tether",
    symbol: "USDT",
    subtitle: "Stablecoin",
    borrowApr: 4.8,
    visual: { symbol: "USDT", shortLabel: "T", bgClassName: "bg-emerald-100", textClassName: "text-emerald-700" },
  },
  {
    id: "wbtc",
    name: "Wrapped Bitcoin",
    symbol: "WBTC",
    subtitle: "Bitcoin",
    borrowApr: 2.9,
    visual: { symbol: "WBTC", shortLabel: "BTC", bgClassName: "bg-amber-100", textClassName: "text-amber-700" },
  },
  {
    id: "weth",
    name: "Wrapped Ether",
    symbol: "WETH",
    subtitle: "Wrapped native",
    borrowApr: 4.0,
    visual: { symbol: "WETH", shortLabel: "W", bgClassName: "bg-muted", textClassName: "text-foreground" },
  },
  {
    id: "dai",
    name: "Dai",
    symbol: "DAI",
    subtitle: "MakerDAO stablecoin",
    borrowApr: 5.7,
    visual: { symbol: "DAI", shortLabel: "D", bgClassName: "bg-orange-100", textClassName: "text-orange-700" },
  },
  {
    id: "gho",
    name: "GHO",
    symbol: "GHO",
    subtitle: "Aave stablecoin",
    borrowApr: 3.9,
    visual: { symbol: "GHO", shortLabel: "G", bgClassName: "bg-violet-100", textClassName: "text-violet-700" },
  },
  {
    id: "link",
    name: "Chainlink",
    symbol: "LINK",
    subtitle: "Oracle network",
    borrowApr: 3.2,
    visual: { symbol: "LINK", shortLabel: "L", bgClassName: "bg-blue-100", textClassName: "text-blue-700" },
  },
  {
    id: "uni",
    name: "Uniswap",
    symbol: "UNI",
    subtitle: "Governance",
    borrowApr: 3.5,
    visual: { symbol: "UNI", shortLabel: "U", bgClassName: "bg-pink-100", textClassName: "text-pink-700" },
  },
  {
    id: "aave",
    name: "Aave",
    symbol: "AAVE",
    subtitle: "Governance",
    borrowApr: 2.8,
    visual: { symbol: "AAVE", shortLabel: "A", bgClassName: "bg-purple-100", textClassName: "text-purple-700" },
  },
  {
    id: "arb",
    name: "Arbitrum",
    symbol: "ARB",
    subtitle: "L2 governance",
    borrowApr: 3.1,
    visual: { symbol: "ARB", shortLabel: "A", bgClassName: "bg-cyan-100", textClassName: "text-cyan-700" },
  },
  {
    id: "op",
    name: "Optimism",
    symbol: "OP",
    subtitle: "L2 governance",
    borrowApr: 3.0,
    visual: { symbol: "OP", shortLabel: "O", bgClassName: "bg-rose-100", textClassName: "text-rose-700" },
  },
  {
    id: "ldo",
    name: "Lido DAO",
    symbol: "LDO",
    subtitle: "Liquid staking",
    borrowApr: 4.4,
    visual: { symbol: "LDO", shortLabel: "L", bgClassName: "bg-sky-100", textClassName: "text-sky-700" },
  },
  {
    id: "mkr",
    name: "Maker",
    symbol: "MKR",
    subtitle: "Governance",
    borrowApr: 3.7,
    visual: { symbol: "MKR", shortLabel: "M", bgClassName: "bg-teal-100", textClassName: "text-teal-700" },
  },
]

export const HOME_CLAIM_POSITIONS: HomeClaimPosition[] = [
  {
    id: "claim-eth-usdc",
    poolId: "eth-usdc",
    name: "ETH / USDC",
    subtitle: "Uni v3 · Bluechip · 0.3%",
    totalUsd: 111.1,
    breakdown: [
      {
        id: "claim-eth-usdc-eth",
        symbol: "ETH",
        amountLabel: "0.0210 ETH",
        usdValue: 68.99,
        visual: { symbol: "ETH", shortLabel: "ETH", bgClassName: "bg-indigo-100", textClassName: "text-indigo-600" },
      },
      {
        id: "claim-eth-usdc-usdc",
        symbol: "USDC",
        amountLabel: "42.11 USDC",
        usdValue: 42.11,
        visual: { symbol: "USDC", shortLabel: "U", bgClassName: "bg-sky-100", textClassName: "text-sky-700" },
      },
    ],
  },
  {
    id: "claim-usdc-usdt",
    poolId: "usdc-usdt",
    name: "USDC / USDT",
    subtitle: "Uni v3 · Stable · 0.01%",
    totalUsd: 62.4,
    breakdown: [
      {
        id: "claim-usdc-usdt-usdc",
        symbol: "USDC",
        amountLabel: "42.11 USDC",
        usdValue: 42.11,
        visual: { symbol: "USDC", shortLabel: "U", bgClassName: "bg-sky-100", textClassName: "text-sky-700" },
      },
      {
        id: "claim-usdc-usdt-usdt",
        symbol: "USDT",
        amountLabel: "20.29 USDT",
        usdValue: 20.29,
        visual: { symbol: "USDT", shortLabel: "T", bgClassName: "bg-emerald-100", textClassName: "text-emerald-700" },
      },
    ],
  },
  {
    id: "claim-wbtc-eth",
    poolId: "wbtc-eth",
    name: "WBTC / ETH",
    subtitle: "Uni v3 · Bluechip · 0.3%",
    totalUsd: 79.6,
    breakdown: [
      {
        id: "claim-wbtc-eth-wbtc",
        symbol: "WBTC",
        amountLabel: "0.0011 WBTC",
        usdValue: 48.1,
        visual: { symbol: "WBTC", shortLabel: "BTC", bgClassName: "bg-amber-100", textClassName: "text-amber-700" },
      },
      {
        id: "claim-wbtc-eth-eth",
        symbol: "ETH",
        amountLabel: "0.0094 ETH",
        usdValue: 31.5,
        visual: { symbol: "ETH", shortLabel: "ETH", bgClassName: "bg-indigo-100", textClassName: "text-indigo-600" },
      },
    ],
  },
]

export const HOME_INITIAL_CLAIM_SELECTIONS: Record<string, boolean> = {
  "claim-eth-usdc": true,
  "claim-usdc-usdt": true,
  "claim-wbtc-eth": false,
}

export const HOME_INITIAL_CLAIMABLE_TOTALS: Record<string, number> = {}
for (const position of HOME_CLAIM_POSITIONS) {
  HOME_INITIAL_CLAIMABLE_TOTALS[position.id] = position.totalUsd
}

export const HOME_DEFAULT_SELECTIONS = {
  borrowPoolId: "eth-usdc",
  borrowTokenId: "usdc",
  repayPoolId: "eth-usdc",
  removePoolId: "eth-usdc",
  removePercent: 25,
}

export function formatUsd(value: number) {
  // Currency-aware (matches the sibling formatCompactUsd and the header switcher);
  // previously hardcoded "$", so "Claim $X in fees" stayed USD under EUR/etc.
  const { symbol, rate } = getActiveCurrency()
  const converted = value * rate
  return `${symbol}${converted.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
}

export function formatCompactUsd(usdValue: number) {
  const { symbol, rate } = getActiveCurrency()
  const value = usdValue * rate
  return `${symbol}${value.toLocaleString("en-US", { maximumFractionDigits: value >= 100 ? 0 : 2 })}`
}

// A position whose debt is a rounding-dust fraction of its collateral produces a
// mathematically-finite but meaninglessly-large health factor (e.g. 18369.7).
// Treat anything at or above this as effectively infinite so the display reads "∞"
// consistently instead of an alarming raw number.
const HEALTH_FACTOR_INFINITE_THRESHOLD = 1_000

export function formatHealthFactor(value: number | null) {
  if (value === null || Number.isNaN(value)) {
    return "—"
  }

  if (!Number.isFinite(value) || value >= HEALTH_FACTOR_INFINITE_THRESHOLD) {
    return "∞"
  }

  return value.toFixed(2)
}

export function getPoolById(poolId: string) {
  return HOME_COLLATERAL_POOLS.find((pool) => pool.id === poolId) ?? HOME_COLLATERAL_POOLS[0]
}

export function getBorrowTokenById(tokenId: string) {
  return HOME_BORROW_TOKENS.find((token) => token.id === tokenId) ?? HOME_BORROW_TOKENS[0]
}

export function getClaimPositionById(positionId: string) {
  return HOME_CLAIM_POSITIONS.find((position) => position.id === positionId) ?? HOME_CLAIM_POSITIONS[0]
}

export function getRiskTone(healthFactor: number | null): HomeRiskTone {
  const band = healthFactorBand(healthFactor)
  if (band.id === "unknown") return "neutral"
  if (band.tone === "positive") return "positive"
  if (band.tone === "danger") return "danger"
  return "warning"
}

type HealthStatus = {
  label: string
  dotClass: string
  textClass: string
  barClass: string
}

export function getHealthStatus(hf: number): HealthStatus {
  const band = healthFactorBand(hf)
  return {
    label: band.label.toUpperCase(),
    dotClass: band.status.dotClass,
    textClass: band.status.textClass,
    barClass: band.status.barClass,
  }
}

export const MAX_LTV = 0.8
export const LIQUIDATION_LTV = 0.83

export function calculateBorrowPreview(
  pool: HomeCollateralPool,
  amountUsd: number,
  tokenSymbol: string,
): BorrowPreview {
  if (amountUsd <= 0) {
    return {
      amountUsd,
      amountLabel: "—",
      isEmpty: true,
      isValid: false,
      exceedsBorrowPower: false,
      healthFactor: null,
      healthFactorLabel: "—",
      riskTone: "neutral",
      progressPercent: 5,
      remainingBorrowPowerUsd: pool.borrowPowerUsd,
      warningTitle: null,
      warningMessage: null,
      ctaLabel: "Enter an amount",
    }
  }

  // Health factor uses the LIQUIDATION THRESHOLD, not the borrow max-LTV, so it
  // matches the canonical engine definition (credit-engine/metrics.ts:99):
  // HF = (collateral * liquidationThreshold) / debt. The pool carries a pre-scaled
  // liquidation USD figure (collateralUsd * liquidationThreshold), so for a borrow
  // against the full collateral this is simply liquidationUsd / debt.
  const healthFactor = pool.liquidationUsd / amountUsd
  const exceedsBorrowPower = amountUsd > pool.borrowPowerUsd
  const riskTone = getRiskTone(healthFactor)
  const progressPercent = Math.max(5, Math.min(90, 90 - (amountUsd / pool.borrowPowerUsd) * 85))
  const remainingBorrowPowerUsd = Math.max(0, pool.borrowPowerUsd - amountUsd)

  let warningTitle: string | null = null
  let warningMessage: string | null = null

  if (riskTone === "danger") {
    warningTitle = "High liquidation risk"
    warningMessage = `Health factor: ${formatHealthFactor(healthFactor)}.`
  } else if (riskTone === "warning") {
    warningTitle = "Borrowing gets tighter"
    warningMessage = `Health factor: ${formatHealthFactor(healthFactor)}.`
  }

  return {
    amountUsd,
    amountLabel: formatUsd(amountUsd),
    isEmpty: false,
    isValid: !exceedsBorrowPower,
    exceedsBorrowPower,
    healthFactor,
    healthFactorLabel: formatHealthFactor(healthFactor),
    riskTone,
    progressPercent,
    remainingBorrowPowerUsd,
    warningTitle,
    warningMessage,
    ctaLabel: exceedsBorrowPower ? "Exceeds borrow power" : `Borrow ${amountUsd.toFixed(0)} ${tokenSymbol}`,
  }
}

export function calculateRepayPreview(
  pool: HomeCollateralPool,
  currentDebtUsd: number,
  amountUsd: number,
  borrowApr: number,
): RepayPreview {
  if (amountUsd <= 0) {
    return {
      amountUsd,
      isEmpty: true,
      isValid: false,
      exceedsDebt: false,
      remainingDebtUsd: currentDebtUsd,
      remainingDebtLabel: formatCompactUsd(currentDebtUsd),
      healthFactorAfter: currentDebtUsd > 0 ? pool.liquidationUsd / currentDebtUsd : Number.POSITIVE_INFINITY,
      healthFactorAfterLabel: currentDebtUsd > 0 ? formatHealthFactor(pool.liquidationUsd / currentDebtUsd) : "∞",
      oldHealthFactorLabel: currentDebtUsd > 0 ? formatHealthFactor(pool.liquidationUsd / currentDebtUsd) : "∞",
      riskTone: currentDebtUsd > 0 ? getRiskTone(pool.liquidationUsd / currentDebtUsd) : "positive",
      yearlyInterestSavedUsd: 0,
      ctaLabel: "Enter an amount",
    }
  }

  const remainingDebtUsd = Math.max(0, currentDebtUsd - amountUsd)
  // HF uses the liquidation threshold (pre-scaled into pool.liquidationUsd), not max-LTV.
  const healthFactorAfter = remainingDebtUsd > 0 ? pool.liquidationUsd / remainingDebtUsd : Number.POSITIVE_INFINITY
  const oldHealthFactor = currentDebtUsd > 0 ? pool.liquidationUsd / currentDebtUsd : Number.POSITIVE_INFINITY
  const exceedsDebt = amountUsd > currentDebtUsd

  return {
    amountUsd,
    isEmpty: false,
    isValid: !exceedsDebt,
    exceedsDebt,
    remainingDebtUsd,
    remainingDebtLabel: `${formatCompactUsd(remainingDebtUsd)} USDC`,
    healthFactorAfter,
    healthFactorAfterLabel: formatHealthFactor(healthFactorAfter),
    oldHealthFactorLabel: formatHealthFactor(oldHealthFactor),
    riskTone: getRiskTone(healthFactorAfter),
    yearlyInterestSavedUsd: (amountUsd * borrowApr) / 100,
    ctaLabel: exceedsDebt ? "Exceeds debt" : `Repay ${formatCompactUsd(amountUsd)} USDC`,
  }
}

export function calculateClaimPreview(
  positions: HomeClaimPosition[],
  claimableTotals: Record<string, number>,
  selections: Record<string, boolean>,
  partialAmountUsd: number | null,
): ClaimPreview {
  const selectedPositionIds = positions.filter((position) => selections[position.id]).map((position) => position.id)
  const selectedTotalUsd = selectedPositionIds.reduce((sum, positionId) => sum + (claimableTotals[positionId] ?? 0), 0)
  const hasCustomAmount = partialAmountUsd !== null && partialAmountUsd > 0
  const effectiveClaimUsd = hasCustomAmount ? Math.min(partialAmountUsd ?? 0, selectedTotalUsd) : selectedTotalUsd
  // Claim breakdown is token harvest only — never list "Fees" as a green claimable
  // reward leg beside ETH/USDC (that confused fee cost with rewards).
  const tokenTotals = positions.reduce<Record<string, number>>((accumulator, position) => {
    if (!selections[position.id]) {
      return accumulator
    }

    position.breakdown.forEach((item) => {
      if (item.symbol === "Fees") return
      accumulator[item.symbol] = (accumulator[item.symbol] ?? 0) + item.usdValue
    })

    return accumulator
  }, {})

  return {
    selectedPositionIds,
    selectedTotalUsd,
    effectiveClaimUsd,
    hasSelection: selectedPositionIds.length > 0,
    hasCustomAmount,
    ctaLabel:
      selectedPositionIds.length > 0 ? `Claim ${formatUsd(effectiveClaimUsd)} in fees` : "Select positions to claim",
    helperLabel: hasCustomAmount ? "Partial claim from selected positions" : "Leave empty to claim all selected",
    tokenTotals,
  }
}

function calculateSafeRemovePercent(pool: HomeCollateralPool, currentDebtUsd: number) {
  if (currentDebtUsd <= 0) {
    return 100
  }

  return Math.max(
    0,
    Math.min(100, Math.floor((1 - currentDebtUsd / ((pool.collateralUsd * (pool.maxLtv / 100)) / 1.5)) * 100)),
  )
}

export function calculateRemovePreview(
  pool: HomeCollateralPool,
  currentDebtUsd: number,
  percent: number,
): RemovePreview {
  const removeUsd = Math.round((pool.collateralUsd * percent) / 100)
  const afterCollateralUsd = pool.collateralUsd - removeUsd
  // Liquidation threshold ratio pre-scaled into the pool (liquidationUsd / collateralUsd,
  // ≈0.805). HF uses this threshold applied to the REMAINING collateral, matching the
  // canonical engine definition (credit-engine/metrics.ts:99) rather than the borrow max-LTV.
  const liquidationThreshold = pool.collateralUsd > 0 ? pool.liquidationUsd / pool.collateralUsd : 0
  const liquidationThresholdAfterUsd = Math.round(afterCollateralUsd * liquidationThreshold)
  const healthFactorAfter =
    currentDebtUsd > 0 ? (afterCollateralUsd * liquidationThreshold) / currentDebtUsd : Number.POSITIVE_INFINITY
  const safePercent = calculateSafeRemovePercent(pool, currentDebtUsd)
  const isUnsafe = currentDebtUsd > 0 && percent > safePercent
  // Block the removal when it would push the position below the safe floor (percent >
  // safePercent) or, worse, make it insolvent (HF-after < 1.0). Mirrors how BorrowPreview
  // and RepayPreview gate on isValid.
  const isValid = !isUnsafe && healthFactorAfter >= 1.0

  return {
    percent,
    safePercent,
    removeUsd,
    afterCollateralUsd,
    healthFactorAfter,
    healthFactorAfterLabel: formatHealthFactor(healthFactorAfter),
    riskTone: getRiskTone(healthFactorAfter),
    isUnsafe,
    isValid,
    liquidationThresholdAfterUsd,
    ctaLabel: isValid ? `Remove ${percent}% · ${formatCompactUsd(removeUsd)}` : "Reduce removal amount",
  }
}
