// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Liquidation and revenue totals. Liquidations of a market over a time range come from its settled liquidations
// (`LPVaultSwap.LiquidationSettled`: units seized, debt repaid) and reported deficits (`AaveSpoke.ReportDeficit`,
// drawn shares × drawn index), each valued at the price of the hour the event happened when that hour's bucket is
// known, else at the current price. Revenue of a Hub asset over one day is the interest borrowers paid that day
// (owed × drawn rate / 365 at that day's price) and the Hub's share of it (the liquidity fee).

import { rayToAprPct, usd } from "@avana/services-common/views";
import type { Values } from "./charts.ts";
import type { LiquidationWindow } from "./riskViews.ts";

export interface LiquidationLog {
  readonly kind: string;
  readonly at: number;
  readonly args: Readonly<Record<string, unknown>>;
  readonly spokeReserveKey?: string;
}

/** Prices at the hour of an event: USD 8 decimals, decimals of the token, and the drawn index for deficits. */
export interface LiquidationPricing {
  collateral(atMs: number): { priceUsd8: bigint; decimals: number } | null;
  debt(reserveId: string, atMs: number): { priceUsd8: bigint; decimals: number } | null;
  deficit(spokeReserveKey: string, atMs: number): { priceUsd8: bigint; decimals: number; drawnIndexRay: bigint } | null;
}

const toUsd = (units: bigint, priceUsd8: bigint, decimals: number) => Number((units * priceUsd8) / 10n ** BigInt(decimals)) / 1e8;

export function liquidationTotals(logs: readonly LiquidationLog[], from: number, to: number, p: LiquidationPricing): LiquidationWindow {
  let liquidations = 0;
  let collateralSeizedUsd = 0;
  let debtRepaidUsd = 0;
  let badDebtUsd = 0;
  for (const l of logs) {
    if (l.at < from || l.at >= to) continue;
    if (l.kind === "AaveSpoke.ReportDeficit") {
      const d = l.spokeReserveKey ? p.deficit(l.spokeReserveKey, l.at) : null;
      if (d) badDebtUsd += toUsd((BigInt(String(l.args.drawnShares)) * d.drawnIndexRay) / 10n ** 27n, d.priceUsd8, d.decimals);
      continue;
    }
    if (l.kind !== "LPVaultSwap.LiquidationSettled") continue;
    const report = l.args.report as { debtReserveId: string; debtRepaid: string; unitsSeized: string };
    liquidations += 1;
    const c = p.collateral(l.at);
    if (c) collateralSeizedUsd += toUsd(BigInt(report.unitsSeized), c.priceUsd8, c.decimals);
    const d = p.debt(String(report.debtReserveId), l.at);
    if (d) debtRepaidUsd += toUsd(BigInt(report.debtRepaid), d.priceUsd8, d.decimals);
  }
  return { liquidations, collateralSeizedUsd, debtRepaidUsd, badDebtUsd };
}

/** The value of `metric` in the hourly bucket holding `atMs`, from buckets keyed by start second. */
export function hourValue(hours: ReadonlyMap<number, Values>, atMs: number, metric: string): string | undefined {
  return hours.get(Math.floor(atMs / 1000 / 3_600) * 3_600)?.[metric];
}

export interface RevenueDay {
  readonly interestUsd: number;
  readonly reserveUsd: number;
  readonly suppliersUsd: number;
}

/** One day of a Hub asset's interest from its daily bucket. */
export function revenueDay(day: Values, decimals: number, liquidityFeeBps: number): RevenueDay {
  const interestUsd = (usd(day.owed ?? "0", decimals, day.priceUsd8 ?? "0") * (rayToAprPct(day.drawnRateRay ?? "0") / 100)) / 365;
  const reserveUsd = (interestUsd * liquidityFeeBps) / 10_000;
  return { interestUsd, reserveUsd, suppliersUsd: interestUsd - reserveUsd };
}

/** `YYYY-MM-DD` of the UTC day before the one holding `nowMs`, and its bounds in ms. */
export function previousUtcDay(nowMs: number): { day: string; from: number; to: number } {
  const to = Math.floor(nowMs / 86_400_000) * 86_400_000;
  const from = to - 86_400_000;
  return { day: new Date(from).toISOString().slice(0, 10), from, to };
}
