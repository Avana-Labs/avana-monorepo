export type BorrowSpokeBreakdown = {
  spokeId: string
  label: string
  availableCreditUsd: number
  totalBorrowedUsd: number
  liquidationBufferUsd: number
  healthFactor: number | null
}

export type BorrowSnapshot = {
  approvedUsd: number
  liquidationThresholdUsd: number
  totalBorrowedUsd: number
  totalCollateralUsd: number
  averageHealthFactor: number | null
  currentLtvPct: number
  spokeBreakdown?: BorrowSpokeBreakdown[]
}
