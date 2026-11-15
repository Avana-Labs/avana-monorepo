// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Rates over the 1D, 30D and 90D windows of the detail pages, and the LP fee APR of a market's position range.
//
// LP fee APR. A concentrated-liquidity position earns the pool's fees in proportion to its liquidity L while the
// price is inside its range. Over a window, the fees one unit of in-range liquidity earned are Σ_buckets fees_b / L_b
// (L_b the pool's active liquidity at the bucket's last swap, the same quantity the pool's fee growth divides by).
// The value of one unit of L across the market's range [tickLower, tickUpper] at the current price P is
//   amount0 = 1/√P − 1/√Pb (P below Pb), amount1 = √P − √Pa (P above Pa),
// in raw units of each token. APR = fees per unit L × 365 / days / value of one unit L. A price outside the market's
// range earns nothing, so the APR is 0 there. Example: $1,000 of fees a day with L = 1e12 and a range whose unit
// of L is worth $1e-6 gives 1,000 / 1e12 / 1e-6 × 365 = 36.5 %.

import { rayToAprPct, rayToApyPct } from "@avana/services-common/views";
import type { Values } from "./charts.ts";

export const WINDOWS = { "1D": 1, "30D": 30, "90D": 90 } as const;
export type WindowId = keyof typeof WINDOWS;

const Q96 = 2 ** 96;
const sqrtAtTick = (tick: number) => Math.pow(1.0001, tick / 2);

export interface PoolPricing {
  readonly decimals: readonly [number, number];
  /** USD per whole token. */
  readonly priceUsd: readonly [number, number];
}

/** USD value of one unit of liquidity spread over [tickLower, tickUpper] at `sqrtPriceX96`; 0 outside the range. */
export function valuePerLiquidityUsd(sqrtPriceX96: string, tickLower: number, tickUpper: number, p: PoolPricing): number {
  const s = Number(BigInt(sqrtPriceX96)) / Q96;
  const a = sqrtAtTick(tickLower);
  const b = sqrtAtTick(tickUpper);
  if (!(s > a && s < b)) return 0;
  const amount0 = 1 / s - 1 / b;
  const amount1 = s - a;
  return (amount0 / 10 ** p.decimals[0]) * p.priceUsd[0] + (amount1 / 10 ** p.decimals[1]) * p.priceUsd[1];
}

/** Fees one unit of active liquidity earned in USD over the given buckets (both tokens). */
export function feesPerLiquidityUsd(buckets: Iterable<Values>, p: PoolPricing): number {
  let total = 0;
  for (const v of buckets) {
    const l = Number(v.liquidity ?? "0");
    if (!(l > 0)) continue;
    const usd = (Number(v.fees0 ?? "0") / 10 ** p.decimals[0]) * p.priceUsd[0] + (Number(v.fees1 ?? "0") / 10 ** p.decimals[1]) * p.priceUsd[1];
    total += usd / l;
  }
  return total;
}

/** LP fee APR in percent of a market's range over `days` of pool buckets, at the current price; 0 out of range. */
export function lpFeeAprPct(buckets: Iterable<Values>, days: number, current: { sqrtPriceX96: string; tickLower: number; tickUpper: number }, p: PoolPricing): number {
  const unit = valuePerLiquidityUsd(current.sqrtPriceX96, current.tickLower, current.tickUpper, p);
  if (unit <= 0 || days <= 0) return 0;
  return (feesPerLiquidityUsd(buckets, p) / unit) * (365 / days) * 100;
}

/** Average supply APY and borrow APR of a Hub asset's daily buckets (each day weighted equally). */
export function rateAverages(buckets: readonly Values[]): { supplyApyPct: number; borrowAprPct: number; utilizationPct: number } | null {
  const days = buckets.filter((v) => v.drawnRateRay !== undefined);
  if (days.length === 0) return null;
  const avg = (f: (v: Values) => number) => days.reduce((acc, v) => acc + f(v), 0) / days.length;
  return {
    supplyApyPct: avg((v) => rayToApyPct(v.supplyRateRay ?? "0")),
    borrowAprPct: avg((v) => rayToAprPct(v.drawnRateRay ?? "0")),
    utilizationPct: avg((v) => Number(v.utilizationBps ?? "0") / 100),
  };
}
