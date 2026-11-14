/**
 * Keep lend detail headline util/APR on the Convex snapshot path.
 * IRM may supply curve protocol parameters only — never overwrite live tips.
 */
export function resolveLendHeadlineRates(input: {
  snapshotBacked: boolean
  detailUtilizationPct: number
  detailBorrowAprPct: number
  irmUtilizationPct?: number
  irmBorrowAprPct?: number
}) {
  if (input.snapshotBacked) {
    return {
      utilizationPct: input.detailUtilizationPct,
      borrowAprPct: input.detailBorrowAprPct,
    }
  }
  return {
    utilizationPct: input.irmUtilizationPct ?? input.detailUtilizationPct,
    borrowAprPct: input.irmBorrowAprPct ?? input.detailBorrowAprPct,
  }
}
