// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Which way to fund one liquidation. The bot is a committed operator: it liquidates every account below health
// factor 1 whether or not the bonus pays, so "skip" happens only for a healthy account or an empty debt.

export const ONE = 10n ** 18n;

export interface Situation {
  /** 18-decimal health factor. */
  readonly healthFactor: bigint;
  /** The account's debt in the reserve. */
  readonly debt: bigint;
  /** The bot's own balance of the debt asset. */
  readonly balance: bigint;
  /** Whether a FlashLiquidator is configured. */
  readonly flash: boolean;
  /** Whether the Aave DAO granted the FlashLiquidator `FLASH_BORROWER` (no premium). */
  readonly flashBorrower: boolean;
}

export type Decision =
  | { readonly kind: "skip"; readonly reason: "healthy" | "no debt" }
  | { readonly kind: "direct"; readonly debtToCover: bigint }
  | { readonly kind: "flash"; readonly flashAmount: bigint }
  | { readonly kind: "unfunded"; readonly debt: bigint };

/**
 * Offers the whole debt: Aave takes only what brings the account to its target health factor and the module refunds
 * the rest. A premium-free flash loan is preferred, since it keeps the bot's own funds for when the Pool is short; with
 * a premium, the bot's own funds go first.
 */
export function decide(s: Situation): Decision {
  if (s.healthFactor >= ONE) return { kind: "skip", reason: "healthy" };
  if (s.debt === 0n) return { kind: "skip", reason: "no debt" };
  if (s.flash && s.flashBorrower) return { kind: "flash", flashAmount: s.debt };
  if (s.balance >= s.debt) return { kind: "direct", debtToCover: s.debt };
  if (s.flash) return { kind: "flash", flashAmount: s.debt };
  if (s.balance > 0n) return { kind: "direct", debtToCover: s.balance };
  return { kind: "unfunded", debt: s.debt };
}

/** The least profit to accept after the simulated one: `slippageBps` of it may be lost to price moves. */
export function minProfit(simulated: bigint, slippageBps: bigint): bigint {
  return (simulated * (10_000n - slippageBps)) / 10_000n;
}
