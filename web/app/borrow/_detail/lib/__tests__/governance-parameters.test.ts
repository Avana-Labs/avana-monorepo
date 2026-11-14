import { describe, expect, it } from "vitest"
import {
  RISK_PARAMETER_LABELS,
  normalizeGovernanceParameters,
  withGovernanceParameterView,
} from "../governance-parameters"

describe("risk parameter normalization", () => {
  it("rewrites the IRM five-pack into the eight risk parameters, leaving unknown ones empty", () => {
    const about = withGovernanceParameterView(
      {
        description: "x",
        stats: [],
        history: [{ date: "2025-01-01", title: "Listed", description: "Opened" }],
      },
      [
        { id: "collateralFactor", label: "Collateral factor", value: "63.5%" },
        { id: "optimalUtilization", label: "Optimal utilization", value: "83%" },
        { id: "slopeBelowOptimal", label: "Slope below optimal", value: "5.3%" },
        { id: "slopeAboveOptimal", label: "Slope above optimal", value: "61%" },
        { id: "baseBorrowRate", label: "Base borrow rate", value: "0.42%" },
      ],
    )

    expect(about.governanceParameters?.parameters.map((parameter) => parameter.label)).toEqual(RISK_PARAMETER_LABELS)
    expect(about.governanceParameters?.parameters.map((parameter) => parameter.value)).toEqual([
      "63.5%",
      "—",
      "—",
      "—",
      "—",
      "—",
      "63.50%",
      "—",
    ])
  })

  it("keeps an already-complete risk set", () => {
    const about = normalizeGovernanceParameters({
      description: "x",
      stats: [],
      history: [],
      governanceParameters: {
        parameters: [
          { id: "collateralFactor", label: "Collateral factor", value: "78.00%" },
          { id: "collateralRisk", label: "Collateral risk", value: "5.00%" },
          { id: "depositCapacity", label: "Deposit capacity", value: "$120.0M" },
          { id: "liquidationPenalty", label: "Liquidation penalty", value: "5.00% - 5.55%" },
          { id: "borrowCapacity", label: "Borrow capacity", value: "$40.0M" },
          { id: "targetHealthFactor", label: "Target health factor", value: "1.28" },
          { id: "liquidationThreshold", label: "Liquidation threshold", value: "83.00%" },
          { id: "oracle", label: "Oracle source", value: "Chainlink" },
        ],
        changelog: [],
      },
    })

    expect(about.parameters.map((parameter) => parameter.label)).toEqual(RISK_PARAMETER_LABELS)
    expect(about.parameters.map((parameter) => parameter.value)).toEqual([
      "78.00%",
      "5.00%",
      "$120.0M",
      "5.00% - 5.55%",
      "$40.0M",
      "1.28",
      "83.00%",
      "Chainlink",
    ])
  })

  it("prefers the rich governance changelog over the thin history, uncapped", () => {
    const changelog = Array.from({ length: 14 }, (_, i) => ({
      id: `chg-${i}`,
      parameter: "Supply cap",
      previous: "$100M",
      current: "$120M",
      date: `2026-0${(i % 9) + 1}-01`,
      source: "Risk parameter review",
      executor: "Governance executor",
      category: "Risk Management",
    }))
    const about = normalizeGovernanceParameters({
      description: "x",
      stats: [],
      history: [{ date: "2026-03-01", title: "Raised LTV", description: "68% → 75%" }],
      governanceParameters: {
        parameters: [{ id: "collateralFactor", label: "Collateral factor", value: "75.00%" }],
        changelog,
      },
    })

    // Rich changelog wins over about.history, and is not capped at 3.
    expect(about.changelog).toHaveLength(14)
    expect(about.changelog[0]?.parameter).toBe("Supply cap")
    expect(about.changelog[0]?.category).toBe("Risk Management")
  })

  it("falls back to about.history when no rich changelog was seeded", () => {
    const about = normalizeGovernanceParameters({
      description: "x",
      stats: [],
      history: [{ date: "2026-03-01", title: "Raised LTV", description: "68% → 75%" }],
      governanceParameters: {
        parameters: [{ id: "collateralFactor", label: "Collateral factor", value: "75.00%" }],
        changelog: [],
      },
    })

    expect(about.changelog).toHaveLength(1)
    expect(about.changelog[0]?.parameter).toBe("Raised LTV")
    expect(about.changelog[0]?.current).toBe("68% → 75%")
  })
})
