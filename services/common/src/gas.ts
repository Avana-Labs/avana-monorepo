// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The gas limit every service sends with a transaction, from an `eth_estimateGas` at `latest`.
//
// The estimate runs at the latest block's timestamp. A call that touches a Hub asset already accrued in that second
// skips the Hub's accrual in the estimate, and then pays for it when it is mined in a later second: a Lend Spoke
// withdraw measured 31,185 gas in the same second and 35,837 one second later (+4,652, about 15 %). Supply, withdraw,
// borrow, repay, liquidation and settlement all go through Hub accrual, and one call may accrue several Hub assets.
// The limit therefore adds 30 % and a fixed 25,000 gas, which covers the measured gap on a small call (where the
// fixed part dominates) and several accruals on a large one (where the 30 % does).

export const GAS_PAD_NUMERATOR = 13n;
export const GAS_PAD_DENOMINATOR = 10n;
export const GAS_PAD_FIXED = 25_000n;

/** ⌈1.3 × estimate⌉ + 25,000; never below the estimate. */
export function paddedGasLimit(estimate: bigint): bigint {
  if (estimate < 0n) throw new Error("gas estimate must be non-negative");
  return (estimate * GAS_PAD_NUMERATOR + GAS_PAD_DENOMINATOR - 1n) / GAS_PAD_DENOMINATOR + GAS_PAD_FIXED;
}
