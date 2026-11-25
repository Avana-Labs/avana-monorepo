// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// One wallet's account in one market as the app shows it, from Lens `getAccount` (AccountView, REQ-LENS-009/010):
// health factor (null with no debt), collateral and debt in USD, each debt in base units, and the gates that stop
// an action. Aave values are USD × 1e26 and the debt value that × RAY; the average collateral factor is WAD and the
// risk premium basis points (Aave V4 `ISpoke.UserAccountData`).

const MAX_UINT = (1n << 256n) - 1n;
const VALUE_UNIT = 10n ** 26n;
const RAY = 10n ** 27n;

/** The AccountView fields this summary reads; viem decodes the struct to an object with these names. */
export interface AccountViewLike {
  readonly blockNumber: bigint;
  readonly integrationId: number;
  readonly marketId: bigint;
  readonly proxy: string;
  readonly deployed: boolean;
  readonly healthFactor: bigint;
  readonly totalCollateralValue: bigint;
  readonly totalDebtValueRay: bigint;
  readonly avgCollateralFactor: bigint;
  readonly riskPremium: bigint;
  readonly walletFrozen: boolean;
  readonly breakerReasons: number;
  readonly debts: readonly { readonly reserveId: bigint; readonly asset: string; readonly total: bigint; readonly paused: boolean; readonly priceFresh: boolean }[];
  readonly gateStatus?: Readonly<Record<string, unknown>>;
}

export interface AccountSummary {
  /** With `marketId`, the account's market: each integration's RiskModule numbers its own markets. */
  readonly integrationId: number;
  readonly marketId: string;
  readonly proxy: string;
  readonly deployed: boolean;
  /** Null when the account has no debt (Aave reports `2^256 − 1`). */
  readonly healthFactor: number | null;
  readonly collateralUsd: number;
  readonly debtUsd: number;
  readonly avgCollateralFactorBps: number;
  readonly riskPremiumBps: number;
  readonly walletFrozen: boolean;
  readonly breakerReasons: number;
  readonly debts: readonly { readonly reserveId: string; readonly asset: string; readonly total: string; readonly paused: boolean; readonly priceFresh: boolean }[];
  /** The gate flags as booleans, by name (`borrowAllowed`, `withdrawWithDebtAllowed`, ...). */
  readonly gates: Readonly<Record<string, boolean>>;
  readonly blockNumber: string;
}

/** USD with cents kept: integer division to 1e-4 USD, then to a float. */
const toUsd = (value: bigint, unit: bigint) => Number((value * 10_000n) / unit) / 10_000;

export function accountSummary(a: AccountViewLike): AccountSummary {
  const gates: Record<string, boolean> = {};
  for (const [k, v] of Object.entries(a.gateStatus ?? {})) if (typeof v === "boolean") gates[k] = v;
  return {
    integrationId: a.integrationId,
    marketId: a.marketId.toString(),
    proxy: a.proxy.toLowerCase(),
    deployed: a.deployed,
    healthFactor: a.healthFactor === MAX_UINT ? null : Number((a.healthFactor * 10_000n) / 10n ** 18n) / 10_000,
    collateralUsd: toUsd(a.totalCollateralValue, VALUE_UNIT),
    debtUsd: toUsd(a.totalDebtValueRay, VALUE_UNIT * RAY),
    avgCollateralFactorBps: Number(a.avgCollateralFactor / 10n ** 14n),
    riskPremiumBps: Number(a.riskPremium),
    walletFrozen: a.walletFrozen,
    breakerReasons: Number(a.breakerReasons),
    debts: a.debts.filter((d) => d.total > 0n).map((d) => ({ reserveId: d.reserveId.toString(), asset: d.asset.toLowerCase(), total: d.total.toString(), paused: d.paused, priceFresh: d.priceFresh })),
    gates,
    blockNumber: a.blockNumber.toString(),
  };
}
