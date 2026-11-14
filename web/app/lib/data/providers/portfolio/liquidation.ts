type LiquidationSnapshotRow = {
  borrowedUsd: number
  referenceBorrowedUsd: number
  referenceLiquidationUsd: number
}

function calculateLiquidationThresholdUsd({
  borrowedUsd,
  referenceBorrowedUsd,
  referenceLiquidationUsd,
}: LiquidationSnapshotRow) {
  if (borrowedUsd <= 0 || referenceBorrowedUsd <= 0 || referenceLiquidationUsd <= 0) return 0
  return (borrowedUsd / referenceBorrowedUsd) * referenceLiquidationUsd
}

export function calculateLiquidationNumberUsd(rows: LiquidationSnapshotRow[]) {
  return rows.reduce((sum, row) => sum + calculateLiquidationThresholdUsd(row), 0)
}
