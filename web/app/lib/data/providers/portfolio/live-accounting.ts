const USD_SCALE = 1_000_000
const RAY_SCALE = 10n ** 27n

function usd6(value?: string) {
  return Number(BigInt(value ?? "0")) / USD_SCALE
}

export function calculateLiveBorrowDebt(input: {
  debtSharesUsd6: string
  debtIndexRay: string
  principalBorrowedUsd6: string
  borrowRateWad: string
}) {
  const borrowedUsd = Number((BigInt(input.debtSharesUsd6) * BigInt(input.debtIndexRay)) / RAY_SCALE) / USD_SCALE
  const principalUsd = usd6(input.principalBorrowedUsd6)
  const borrowAprPct = Number(BigInt(input.borrowRateWad)) / 10 ** 16
  return {
    borrowedUsd,
    borrowAprPct,
    accruedInterestUsd: Math.max(0, borrowedUsd - principalUsd),
    dailyInterestUsd: (borrowedUsd * borrowAprPct) / 100 / 365,
  }
}

export function allocateDebtByCollateral(debtUsd: number, collateralUsd: number, totalCollateralUsd: number) {
  if (debtUsd <= 0 || collateralUsd <= 0 || totalCollateralUsd <= 0) return 0
  return debtUsd * (collateralUsd / totalCollateralUsd)
}

const MS_PER_YEAR = 365 * 24 * 60 * 60 * 1_000

export function calculateLiveMultiplyPosition(input: {
  collateralUsd: number
  debtUsd: number
  netApyPct: number
  openedAt: number
  now: number
}) {
  const equityUsd = Math.max(0, input.collateralUsd - input.debtUsd)
  const elapsedYears = Math.max(0, input.now - input.openedAt) / MS_PER_YEAR
  const pnlUsd = equityUsd * (input.netApyPct / 100) * elapsedYears
  return {
    exposureUsd: input.collateralUsd,
    equityUsd,
    pnlUsd,
    pnlPct: equityUsd > 0 ? (pnlUsd / equityUsd) * 100 : 0,
  }
}
