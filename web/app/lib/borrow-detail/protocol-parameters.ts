import type { BorrowPoolRow } from "@/app/lib/borrow-sim"
import type { SpokeBorrowableRecord } from "@/app/lib/borrow-system/registry"

export type ProtocolParameterRow = {
  id: string
  label: string
  value: string
}

export type InterestRateModelParams = {
  optimalUtilizationPct: number
  slopeBelowOptimalPct: number
  slopeAboveOptimalPct: number
  baseBorrowRatePct: number
}

function seededUnit(input: string) {
  let hash = 2_166_136_261
  for (let index = 0; index < input.length; index += 1) {
    hash ^= input.charCodeAt(index)
    hash = Math.imul(hash, 1_677_7619)
  }
  return ((hash >>> 0) % 10_000) / 10_000
}

export function buildInterestRateModelParams(seedKey: string, borrowAprPct: number): InterestRateModelParams {
  const seed = seededUnit(seedKey)
  const optimalUtilizationPct = Math.round(78 + seed * 12)
  const slopeBelowOptimalPct = Math.round((3 + seed * 5) * 10) / 10
  const slopeAboveOptimalPct = Math.round(45 + seed * 35)
  const baseBorrowRatePct = Math.max(0.05, Math.round(borrowAprPct * (0.12 + seed * 0.08) * 100) / 100)

  return {
    optimalUtilizationPct,
    slopeBelowOptimalPct,
    slopeAboveOptimalPct,
    baseBorrowRatePct,
  }
}

function formatInterestRateModelRows(params: InterestRateModelParams): ProtocolParameterRow[] {
  return [
    {
      id: "optimalUtilization",
      label: "Optimal utilization",
      value: `${params.optimalUtilizationPct}%`,
    },
    {
      id: "slopeBelowOptimal",
      label: "Slope below optimal",
      value: `${params.slopeBelowOptimalPct}%`,
    },
    {
      id: "slopeAboveOptimal",
      label: "Slope above optimal",
      value: `${params.slopeAboveOptimalPct}%`,
    },
    {
      id: "baseBorrowRate",
      label: "Base borrow rate",
      value: `${params.baseBorrowRatePct.toFixed(2)}%`,
    },
  ]
}

/** IRM parameter rows for any market keyed by seed + current borrow APR. */
export function buildInterestRateModelParameterRows(seedKey: string, borrowAprPct: number): ProtocolParameterRow[] {
  return formatInterestRateModelRows(buildInterestRateModelParams(seedKey, borrowAprPct))
}

export function buildAssetProtocolParameters(asset: SpokeBorrowableRecord): ProtocolParameterRow[] {
  return buildInterestRateModelParameterRows(asset.id, asset.borrowApr)
}

export function buildPoolProtocolParameters(row: BorrowPoolRow): ProtocolParameterRow[] {
  const borrowApr = (row.aprMin + row.aprMax) / 2
  return [
    { id: "collateralFactor", label: "Collateral factor", value: `${row.ltv.toFixed(1)}%` },
    ...buildInterestRateModelParameterRows(row.id, borrowApr),
  ]
}

export function resolveInterestRateModelParams(parameters: ProtocolParameterRow[]): InterestRateModelParams {
  const byId = Object.fromEntries(parameters.map((row) => [row.id, row.value])) as Record<string, string | undefined>

  const readPct = (id: string, fallback: number) => {
    const raw = byId[id]
    if (!raw) return fallback
    const numeric = Number.parseFloat(raw.replace(/[^0-9.-]/g, ""))
    return Number.isFinite(numeric) ? numeric : fallback
  }

  return {
    optimalUtilizationPct: readPct("optimalUtilization", 80),
    slopeBelowOptimalPct: readPct("slopeBelowOptimal", 4),
    slopeAboveOptimalPct: readPct("slopeAboveOptimal", 60),
    baseBorrowRatePct: readPct("baseBorrowRate", 0.5),
  }
}
