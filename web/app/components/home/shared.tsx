import type { HomeCollateralPool } from "@/app/lib/home-sim"

export function computeHealthFactor(pool: HomeCollateralPool, debtUsd: number): number {
  if (debtUsd <= 0) return Number.POSITIVE_INFINITY
  return pool.liquidationUsd / debtUsd
}
