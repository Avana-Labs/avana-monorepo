import type { AboutCard, QuickStat } from "@/app/lib/borrow-detail"
import type { ProtocolParameterRow } from "@/app/lib/borrow-detail/protocol-parameters"
import { liquidationThresholdPctFromMaxLtvPct } from "@/app/lib/borrow-system/liquidation-threshold"

type ParameterInput = Pick<ProtocolParameterRow, "id" | "label" | "value"> | Pick<QuickStat, "id" | "label" | "value">
type GovernanceParameters = NonNullable<AboutCard["governanceParameters"]>
type GovernanceParameter = GovernanceParameters["parameters"][number]

/**
 * Canonical Risk Parameters grid (2×4 on desktop, 2-col on mobile).
 * Morpho-aligned set without Hub/Market.
 */
const LEND_RISK_PARAMETERS = [
  {
    id: "collateralFactor",
    label: "Collateral factor",
    aliases: ["collateral factor", "max ltv", "ltv"],
    description: "Maximum percentage of an asset's value that can be borrowed against",
    fallback: "75.00%",
  },
  {
    id: "collateralRisk",
    label: "Collateral risk",
    aliases: ["collateral risk", "risk premium"],
    description: "Risk premium adjustment applied to borrows backed by this collateral",
    fallback: "0.00%",
  },
  {
    id: "depositCapacity",
    label: "Deposit capacity",
    aliases: ["deposit capacity", "supply cap"],
    description: "Maximum total deposits allowed before the cap is reached",
    fallback: "$25.0M",
  },
  {
    id: "liquidationPenalty",
    label: "Liquidation penalty",
    aliases: ["liquidation penalty", "liquidation bonus"],
    description: "The penalty range applied when this position is liquidated",
    fallback: "5.00% - 5.55%",
  },
  {
    id: "borrowCapacity",
    label: "Borrow capacity",
    aliases: ["borrow capacity", "borrow cap"],
    description: "Maximum total borrows allowed before the cap is reached",
    fallback: "$10.0M",
  },
  {
    id: "targetHealthFactor",
    label: "Target health factor",
    aliases: ["target health factor"],
    description: "The ideal health factor to restore during liquidation",
    fallback: "1.25",
  },
  {
    id: "liquidationThreshold",
    label: "Liquidation threshold",
    aliases: ["liquidation threshold"],
    description: "Health factor begins breaking down when collateral value crosses this threshold.",
    fallback: "80.00%",
  },
  {
    id: "oracle",
    label: "Oracle source",
    aliases: ["oracle source", "oracle"],
    description: "Price feed family used by the market risk engine.",
    fallback: "Chainlink",
  },
] as const

export const RISK_PARAMETER_LABELS = LEND_RISK_PARAMETERS.map((spec) => spec.label)

function isIrmLabel(label: string) {
  const normalized = label.trim().toLowerCase()
  return (
    normalized.includes("optimal utilization") ||
    normalized.includes("optimal utilisation") ||
    normalized.includes("slope below") ||
    normalized.includes("slope above") ||
    normalized.includes("base borrow")
  )
}

function parsePct(value: string) {
  const numeric = Number.parseFloat(value.replace(/[^0-9.-]/g, ""))
  return Number.isFinite(numeric) ? numeric : null
}

function formatPctValue(value: number, digits = 2) {
  return `${value.toFixed(digits)}%`
}

function formatPenaltyRange(value: string) {
  if (value.includes("-")) return value
  const pct = parsePct(value)
  if (pct == null) return value
  const high = Math.round(pct * 1.11 * 100) / 100
  return `${formatPctValue(pct)} - ${formatPctValue(high)}`
}

function sourceFor(title: string, index: number) {
  const normalized = title.toLowerCase()
  if (normalized.includes("deploy")) return "Deployment"
  if (normalized.includes("list") || normalized.includes("onboard")) return "Market onboarding"
  if (normalized.includes("review") || normalized.includes("refresh")) return "Risk parameter review"
  return index === 0 ? "Latest update" : "Protocol note"
}

function pickParameter(
  spec: (typeof LEND_RISK_PARAMETERS)[number],
  byId: Map<string, GovernanceParameter>,
  byLabel: Map<string, GovernanceParameter>,
): GovernanceParameter {
  const found = byId.get(spec.id) ?? spec.aliases.map((alias) => byId.get(alias) ?? byLabel.get(alias)).find(Boolean)
  if (found?.value && !isIrmLabel(found.label)) {
    return {
      id: spec.id,
      label: spec.label,
      value: found.value,
      description: found.description ?? spec.description,
      href: found.href,
      status: found.status,
    }
  }
  return {
    id: spec.id,
    label: spec.label,
    value: spec.fallback,
    description: spec.description,
  }
}

function findIndex(id: (typeof LEND_RISK_PARAMETERS)[number]["id"]) {
  return LEND_RISK_PARAMETERS.findIndex((spec) => spec.id === id)
}

/** Always eight Morpho-aligned risk parameters. Drops IRM rows and fills any gaps. */
export function normalizeGovernanceParameters(about: AboutCard): GovernanceParameters {
  const incoming = about.governanceParameters?.parameters ?? []
  const usable = incoming.filter((parameter) => !isIrmLabel(parameter.label))
  const byId = new Map(usable.map((parameter) => [parameter.id, parameter]))
  const byLabel = new Map(usable.map((parameter) => [parameter.label.trim().toLowerCase(), parameter]))

  // Legacy builders still emit `ltv` / `supplyCap` ids — index those too.
  for (const parameter of usable) {
    if (parameter.id === "ltv") byId.set("collateralFactor", parameter)
    if (parameter.id === "supplyCap") byId.set("depositCapacity", parameter)
    if (parameter.id === "borrowCap") byId.set("borrowCapacity", parameter)
    if (parameter.id === "liquidationBonus") byId.set("liquidationPenalty", parameter)
  }

  const parameters = LEND_RISK_PARAMETERS.map((spec) => pickParameter(spec, byId, byLabel))

  const cfIndex = findIndex("collateralFactor")
  const ltIndex = findIndex("liquidationThreshold")
  const riskIndex = findIndex("collateralRisk")
  const hfIndex = findIndex("targetHealthFactor")
  const penaltyIndex = findIndex("liquidationPenalty")

  const cf = parsePct(parameters[cfIndex]?.value ?? "")
  const ltSpec = LEND_RISK_PARAMETERS[ltIndex]!
  if (cf != null && parameters[ltIndex]?.value === ltSpec.fallback) {
    parameters[ltIndex] = {
      ...parameters[ltIndex]!,
      value: formatPctValue(Math.round(liquidationThresholdPctFromMaxLtvPct(cf) * 10) / 10),
    }
  }

  const lt = parsePct(parameters[ltIndex]?.value ?? "")
  const riskSpec = LEND_RISK_PARAMETERS[riskIndex]!
  if (cf != null && lt != null && parameters[riskIndex]?.value === riskSpec.fallback) {
    parameters[riskIndex] = {
      ...parameters[riskIndex]!,
      value: formatPctValue(Math.max(0, Math.round((lt - cf) * 100) / 100)),
    }
  }

  const hfSpec = LEND_RISK_PARAMETERS[hfIndex]!
  if (cf != null && parameters[hfIndex]?.value === hfSpec.fallback) {
    const target = Math.max(1.1, Math.round((1 / Math.max(0.5, cf / 100)) * 100) / 100)
    parameters[hfIndex] = {
      ...parameters[hfIndex]!,
      value: target.toFixed(2),
    }
  }

  if (parameters[penaltyIndex]) {
    parameters[penaltyIndex] = {
      ...parameters[penaltyIndex]!,
      value: formatPenaltyRange(parameters[penaltyIndex]!.value),
    }
  }

  // The rich governance changelog (Convex `parameterChanges`, or the mock fallback):
  // real previous → current transitions with source/executor/category. This is the
  // authoritative changelog and drives the paginated detail table.
  const fromGovernance = about.governanceParameters?.changelog.filter((entry) => !isIrmLabel(entry.parameter)) ?? []

  // Last-resort fallback: the thin `about.history` timeline (title + description only,
  // no real transitions). Used when no rich changelog was seeded.
  const fromHistory = about.history.map((entry, index) => ({
    id: `${entry.title.toLowerCase().replace(/[^a-z0-9]+/g, "-")}-${index}`,
    parameter: entry.title,
    previous: "—",
    current: entry.description ?? "Updated",
    date: entry.date,
    source: sourceFor(entry.title, index),
    executor: entry.title.toLowerCase().includes("deploy") ? "Deployment executor" : "Governance executor",
  }))

  return {
    parameters,
    changelog: fromGovernance.length > 0 ? fromGovernance : fromHistory,
  }
}

export function withGovernanceParameterView(about: AboutCard, parameters: readonly ParameterInput[] = []): AboutCard {
  if (about.governanceParameters?.parameters.length) {
    return { ...about, governanceParameters: normalizeGovernanceParameters(about) }
  }

  const seeded: AboutCard = {
    ...about,
    governanceParameters: {
      parameters: parameters
        .filter((parameter) => !isIrmLabel(parameter.label))
        .map((parameter) => ({
          id: parameter.id,
          label: parameter.label,
          value: parameter.value,
        })),
      changelog: [],
    },
  }

  return { ...about, governanceParameters: normalizeGovernanceParameters(seeded) }
}

/** Build the canonical eight-parameter Risk Parameters set for mock/Convex seeders. */
export function buildRiskParameterSet(input: {
  collateralFactorPct: number
  liquidationThresholdPct?: number
  depositCapacityLabel: string
  borrowCapacityLabel: string
  liquidationPenaltyPct: number
  oracle?: string
  collateralFactorDescription?: string
}): GovernanceParameter[] {
  const cf = input.collateralFactorPct
  const lt = input.liquidationThresholdPct ?? Math.round(liquidationThresholdPctFromMaxLtvPct(cf) * 10) / 10
  const collateralRisk = Math.max(0, Math.round((lt - cf) * 100) / 100)
  const targetHf = Math.max(1.1, Math.round((1 / Math.max(0.5, cf / 100)) * 100) / 100)
  const penaltyHigh = Math.round(input.liquidationPenaltyPct * 1.11 * 100) / 100

  return [
    {
      id: "collateralFactor",
      label: "Collateral factor",
      value: formatPctValue(cf),
      description:
        input.collateralFactorDescription ?? "Maximum percentage of an asset's value that can be borrowed against",
    },
    {
      id: "collateralRisk",
      label: "Collateral risk",
      value: formatPctValue(collateralRisk),
      description: "Risk premium adjustment applied to borrows backed by this collateral",
    },
    {
      id: "depositCapacity",
      label: "Deposit capacity",
      value: input.depositCapacityLabel,
      description: "Maximum total deposits allowed before the cap is reached",
    },
    {
      id: "liquidationPenalty",
      label: "Liquidation penalty",
      value: `${formatPctValue(input.liquidationPenaltyPct)} - ${formatPctValue(penaltyHigh)}`,
      description: "The penalty range applied when this position is liquidated",
    },
    {
      id: "borrowCapacity",
      label: "Borrow capacity",
      value: input.borrowCapacityLabel,
      description: "Maximum total borrows allowed before the cap is reached",
    },
    {
      id: "targetHealthFactor",
      label: "Target health factor",
      value: targetHf.toFixed(2),
      description: "The ideal health factor to restore during liquidation",
    },
    {
      id: "liquidationThreshold",
      label: "Liquidation threshold",
      value: formatPctValue(lt),
      description: "Health factor begins breaking down when collateral value crosses this threshold.",
    },
    {
      id: "oracle",
      label: "Oracle source",
      value: input.oracle ?? "Chainlink",
      description: "Price feed family used by the market risk engine.",
    },
  ]
}

/**
 * LP collateral is liquidated at the engine's threshold (collateral factor + the fixed spread,
 * see liquidation-threshold.ts), which the Borrow list shows as "LT". The seeded governance row
 * carried collateral factor + 5, so the detail page read 70% where the list and the engine used
 * 75%. Rewrite that row from the collateral factor so every Borrow surface shows one threshold.
 */
export function withEngineLiquidationThreshold(about: AboutCard): AboutCard {
  const parameters = about.governanceParameters?.parameters
  if (!parameters?.length) return about
  const cf = parsePct(parameters.find((parameter) => parameter.id === "collateralFactor")?.value ?? "")
  if (cf == null) return about
  const lt = formatPctValue(Math.round(liquidationThresholdPctFromMaxLtvPct(cf) * 10) / 10)
  return {
    ...about,
    governanceParameters: {
      ...about.governanceParameters!,
      parameters: parameters.map((parameter) =>
        parameter.id === "liquidationThreshold" ? { ...parameter, value: lt } : parameter,
      ),
    },
  }
}
