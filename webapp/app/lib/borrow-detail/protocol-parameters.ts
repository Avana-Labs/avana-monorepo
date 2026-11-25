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

/** Interest rate model rows of a Hub asset, as the services/convex rate curve reports them. */
export function formatInterestRateModelRows(params: InterestRateModelParams): ProtocolParameterRow[] {
  return [
    { id: "optimalUtilization", label: "Optimal utilization", value: `${params.optimalUtilizationPct}%` },
    { id: "slopeBelowOptimal", label: "Slope below optimal", value: `${params.slopeBelowOptimalPct}%` },
    { id: "slopeAboveOptimal", label: "Slope above optimal", value: `${params.slopeAboveOptimalPct}%` },
    { id: "baseBorrowRate", label: "Base borrow rate", value: `${params.baseBorrowRatePct.toFixed(2)}%` },
  ]
}

/**
 * The interest rate model a page's parameter rows describe, or null when any of the four is
 * missing (the curve card then shows its empty state rather than a made-up curve).
 */
export function resolveInterestRateModelParams(parameters: ProtocolParameterRow[]): InterestRateModelParams | null {
  const byId = Object.fromEntries(parameters.map((row) => [row.id, row.value])) as Record<string, string | undefined>
  const readPct = (id: string) => {
    const raw = byId[id]
    if (!raw) return null
    const numeric = Number.parseFloat(raw.replace(/[^0-9.-]/g, ""))
    return Number.isFinite(numeric) ? numeric : null
  }
  const optimalUtilizationPct = readPct("optimalUtilization")
  const slopeBelowOptimalPct = readPct("slopeBelowOptimal")
  const slopeAboveOptimalPct = readPct("slopeAboveOptimal")
  const baseBorrowRatePct = readPct("baseBorrowRate")
  if (
    optimalUtilizationPct === null ||
    slopeBelowOptimalPct === null ||
    slopeAboveOptimalPct === null ||
    baseBorrowRatePct === null
  ) {
    return null
  }
  return { optimalUtilizationPct, slopeBelowOptimalPct, slopeAboveOptimalPct, baseBorrowRatePct }
}
