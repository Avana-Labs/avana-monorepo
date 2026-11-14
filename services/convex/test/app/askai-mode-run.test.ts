// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { describe, expect, it } from "vitest"
import {
  addCollateralToReachHealthFactor,
  buildPositionContext,
  repayToReachHealthFactor,
  type PositionSnapshotInput,
} from "../../convex/lib/askAI/positionContext"
import {
  buildReturnsRun,
  buildRiskRun,
  buildStressRun,
  classifyAskAiMode,
  routeAskAiMode,
  shouldBuildModeRunForTurn,
  modeRunPositionId,
} from "../../convex/lib/askAI/modeRun"

const base: PositionSnapshotInput = {
  positionId: "pos_1",
  product: "borrow",
  collateralValueUsd: 10_000,
  debtValueUsd: 4_000,
  maxLtvPct: 55,
  liquidationThresholdPct: 65,
  borrowApyPct: 5,
  lpFeeApr7dPct: 18.25,
  lastUpdatedAt: 1_700_000_000_000,
}
const ctxSafe = buildPositionContext(base, 1_700_000_100_000) // HF 1.625
const ctxRisky = buildPositionContext({ ...base, debtValueUsd: 5_000 }, 1_700_000_100_000) // HF 1.3

const opts = { queryText: "am I safe?", provenance: "sandbox" }

describe("defensive-action engine", () => {
  it("computes the repay needed to reach a target health factor", () => {
    // target debt 10000*0.65/1.5 = 4333.33; repay from 5000
    expect(repayToReachHealthFactor(ctxRisky, 1.5)).toBeCloseTo(666.667, 2)
    expect(repayToReachHealthFactor(ctxSafe, 1.5)).toBe(0)
  })

  it("computes the collateral needed to reach a target health factor", () => {
    // target collateral 1.5*5000/0.65 = 11538.46; add from 10000
    expect(addCollateralToReachHealthFactor(ctxRisky, 1.5)).toBeCloseTo(1538.46, 2)
  })
})

describe("buildRiskRun", () => {
  it("assembles risk widgets in order off a single snapshot", () => {
    const run = buildRiskRun(ctxSafe, opts)
    expect(run.mode).toBe("risk")
    expect(run.snapshotId).toBe(ctxSafe.snapshotId)
    expect(run.asOf).toBe(ctxSafe.asOf)
    expect(run.widgets.map((w) => w.type)).toEqual([
      "risk_summary",
      "borrow_capacity",
      "collateral_breakdown",
      "liquidation_boundary",
      "assumptions",
    ])
  })

  it("emits defensive actions only when the health factor is below the safe target", () => {
    expect(buildRiskRun(ctxSafe, opts).actions).toEqual([])
    const risky = buildRiskRun(ctxRisky, opts)
    expect(risky.actions.map((a) => a.id)).toEqual(["risk-repay", "risk-add-collateral"])
    expect(risky.actions[0]).toMatchObject({ kind: "repay", amountUsd: 666.67, resultingHealthFactor: 1.5 })
  })
})

describe("buildStressRun", () => {
  it("leads with stress tiles and keeps a single snapshot", () => {
    const run = buildStressRun(ctxSafe, opts)
    expect(run.mode).toBe("stress")
    expect(run.widgets[0]!.type).toBe("stress_tiles")
    expect(run.snapshotId).toBe(ctxSafe.snapshotId)
  })

  it("suggests a survival repay when the deepest shock liquidates", () => {
    // -30% on the risky position: collateral 7000, surviving debt 7000*0.65 = 4550, repay 450
    const run = buildStressRun(ctxRisky, opts)
    expect(run.actions.map((a) => a.id)).toEqual(["stress-repay-30"])
    expect(run.actions[0]).toMatchObject({ kind: "repay", amountUsd: 450 })
  })

  it("suggests nothing when the position survives every preset", () => {
    expect(buildStressRun(ctxSafe, opts).actions).toEqual([])
  })
})

describe("buildReturnsRun", () => {
  it("includes comparable LPs only when candidates are supplied, always ending with assumptions", () => {
    expect(buildReturnsRun(ctxSafe, opts).widgets.map((w) => w.type)).toEqual([
      "carry_summary",
      "fee_vs_interest",
      "assumptions",
    ])
    const withComparables = buildReturnsRun(ctxSafe, {
      ...opts,
      comparableCandidates: [{ id: "a", label: "A", feeApr7dPct: 10 }],
    })
    expect(withComparables.widgets.map((w) => w.type)).toEqual([
      "carry_summary",
      "fee_vs_interest",
      "comparable_lp",
      "assumptions",
    ])
    expect(withComparables.actions).toEqual([])
  })
})

describe("classifyAskAiMode", () => {
  it("classifies scenario questions as stress (winning over risk)", () => {
    expect(classifyAskAiMode("what if ETH falls 20%?")).toBe("stress")
    expect(classifyAskAiMode("stress test my position")).toBe("stress")
    expect(classifyAskAiMode("is my collateral safe if the market crashes?")).toBe("stress")
  })

  it("classifies safety/liquidation questions as risk", () => {
    expect(classifyAskAiMode("am I safe?")).toBe("risk")
    expect(classifyAskAiMode("what is my health factor?")).toBe("risk")
    expect(classifyAskAiMode("how close am I to liquidation?")).toBe("risk")
  })

  it("classifies yield/carry questions as returns", () => {
    expect(classifyAskAiMode("what's my net carry?")).toBe("returns")
    expect(classifyAskAiMode("how much yield am I earning?")).toBe("returns")
  })

  it("returns null when no mode clearly applies", () => {
    expect(classifyAskAiMode("what markets do you support?")).toBeNull()
    expect(classifyAskAiMode("hello")).toBeNull()
  })
})

describe("routeAskAiMode", () => {
  it("reroutes a leverage question asked in Returns mode to Risk", () => {
    expect(routeAskAiMode("should I loop this position?", "returns")).toEqual({ mode: "risk", rerouted: true })
    expect(routeAskAiMode("what leverage can I take?", "returns")).toEqual({ mode: "risk", rerouted: true })
  })

  it("leaves non-leverage questions and other modes untouched", () => {
    expect(routeAskAiMode("what's my yield?", "returns")).toEqual({ mode: "returns", rerouted: false })
    expect(routeAskAiMode("leverage?", "risk")).toEqual({ mode: "risk", rerouted: false })
  })
})

describe("shouldBuildModeRunForTurn", () => {
  it("keeps single-position personal questions eligible", () => {
    expect(shouldBuildModeRunForTurn("am I safe?")).toBe(true)
    expect(shouldBuildModeRunForTurn("what is my net carry?")).toBe(true)
    expect(shouldBuildModeRunForTurn("What is the risk of my current Borrow position?")).toBe(true)
  })

  it("does not attach a first-position card to public or aggregate questions", () => {
    expect(shouldBuildModeRunForTurn("What is the current GHO supply APY?")).toBe(false)
    expect(shouldBuildModeRunForTurn("Show me the current GHO supply APY")).toBe(false)
    expect(shouldBuildModeRunForTurn("Tell me about liquidation risk on Avana")).toBe(false)
    expect(shouldBuildModeRunForTurn("What is the current GHO supply APY and borrow APR in Avana?")).toBe(false)
    expect(shouldBuildModeRunForTurn("What is my weakest health factor across all positions?")).toBe(false)
    expect(shouldBuildModeRunForTurn("If all of my collateral falls by 20%, what happens?")).toBe(false)
  })
})

describe("modeRunPositionId", () => {
  it("uses the simulated position instead of the first position in a risk read", () => {
    expect(
      modeRunPositionId([
        { kind: "position_risk", payload: { positions: [{ positionId: "first" }, { positionId: "weakest" }] } },
        { kind: "stress_position", payload: { positionId: "weakest" } },
      ]),
    ).toBe("weakest")
  })
  it("requires one unambiguous tool-resolved position", () => {
    expect(modeRunPositionId([{ kind: "position_risk", payload: { positions: [{ positionId: "only" }] } }])).toBe(
      "only",
    )
    expect(
      modeRunPositionId([
        { kind: "position_risk", payload: { positions: [{ positionId: "a" }, { positionId: "b" }] } },
      ]),
    ).toBeNull()
    expect(modeRunPositionId([{ kind: "market", payload: { positionId: "untrusted" } }])).toBeNull()
    expect(
      modeRunPositionId([
        { kind: "simulate_borrow", payload: { positionId: "a" } },
        { kind: "stress_position", payload: { positionId: "b" } },
      ]),
    ).toBeNull()
  })
})
