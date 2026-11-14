/** Standard token icon for tables and list rows (matches multiply markets table). */
export const TOKEN_ICON_TABLE_PX = 48

/** Paired-loop container width for a 48px collateral icon (table rows). */
export const TOKEN_ICON_TABLE_PAIR_WIDTH_PX = 58

/** Larger collateral icon for multiply trending highlight cards. */
export const TOKEN_ICON_TRENDING_PX = 64

/** Borrow icon is always 66% of the collateral icon in paired-loop layouts. */
const PAIRED_LOOP_BORROW_SIZE_RATIO = 0.66

export function pairedLoopBorrowPx(collateralPx: number) {
  return Math.round(collateralPx * PAIRED_LOOP_BORROW_SIZE_RATIO)
}

export function pairedLoopContainerWidthPx(collateralPx: number) {
  return Math.round(collateralPx * (TOKEN_ICON_TABLE_PAIR_WIDTH_PX / TOKEN_ICON_TABLE_PX))
}

export type TokenIconTableSize = "table"
