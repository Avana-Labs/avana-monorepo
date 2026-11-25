import { TOKEN_SCALE, mulDiv } from "./units"

/**
 * Borrowed-asset (debt) valuation — the §7 model, kept strictly separate from LP-collateral
 * valuation. A borrowed single token is worth its own amount × its own USD price; the total debt
 * is the sum across borrowed assets. Debt is NEVER valued with an LP price.
 *
 *   BorrowedAssetUSD = BorrowedAmount × TokenPriceUSD
 *   TotalBorrowedUSD = Σ BorrowedAssetUSD
 *
 * Repricing (D2): the engine stores debt in USD6 fixed at borrow time plus an interest index. To
 * keep the USD value tracking the borrowed token's spot price (so a volatile/depegged debt moves),
 * reprice the whole current debt by the price ratio currentPrice/priceAtBorrow — algebraically
 * identical to holding the debt in token units and valuing at the current price. A no-op when the
 * price is unchanged (or unknown), so it never destabilizes a constant-price position.
 */

/** USD6 value of a single borrowed token amount (18-dec) at its own USD6 price. */
export function borrowedAssetUsd6(tokenAmountWad: bigint, priceUsd6: bigint): bigint {
  if (tokenAmountWad <= 0n || priceUsd6 <= 0n) return 0n
  return mulDiv(tokenAmountWad, priceUsd6, TOKEN_SCALE)
}

/** Σ over borrowed single-token positions — the canonical TotalBorrowedUSD. */
export function totalBorrowedUsd6(positions: ReadonlyArray<{ tokenAmountWad: bigint; priceUsd6: bigint }>): bigint {
  return positions.reduce((sum, p) => sum + borrowedAssetUsd6(p.tokenAmountWad, p.priceUsd6), 0n)
}

/**
 * Reprice a USD6 debt figure (principal + accrued interest, fixed at borrow-time price) to the
 * current token price. Returns the input unchanged when either price is missing/non-positive, so
 * legacy positions with no captured borrow-time price are a safe no-op.
 */
export function repriceDebtValueUsd6(
  debtValueUsd6AtBorrow: bigint,
  priceAtBorrowUsd6: bigint | undefined,
  currentPriceUsd6: bigint | undefined,
): bigint {
  if (!priceAtBorrowUsd6 || priceAtBorrowUsd6 <= 0n || !currentPriceUsd6 || currentPriceUsd6 <= 0n) {
    return debtValueUsd6AtBorrow
  }
  return mulDiv(debtValueUsd6AtBorrow, currentPriceUsd6, priceAtBorrowUsd6)
}
