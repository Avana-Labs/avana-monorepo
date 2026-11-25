// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The shape and defaults of the point-redemption rules. No imports: the webapp reads these, so this module must stay free
// of server code (the checks and the database access live in redemption.ts).

export interface RedemptionRules {
  readonly pointsPerStep: number;
  readonly bpsPerStep: number;
  readonly days: number;
  /** The most bps off that redemptions may give a wallet at once, on top of its tenure discount. */
  readonly maxBps: number;
}

/** 1,000 points = 2 bps off for 30 days; at most 2 bps of redeemed discount at once, so one redemption at a time. */
export const DEFAULT_REDEMPTION: RedemptionRules = { pointsPerStep: 1000, bpsPerStep: 2, days: 30, maxBps: 2 };
