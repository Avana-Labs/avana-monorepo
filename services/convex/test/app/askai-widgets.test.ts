// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { describe, expect, it } from "vitest"
import { buildPositionContext, type PositionSnapshotInput } from "../../convex/lib/askAI/positionContext"
import {
  DEFAULT_STRESS_SHOCKS_PCT,
  FEE_WINDOW_DAYS,
  buildAssumptionsWidget,
  buildBorrowCapacityWidget,
  buildCarrySummaryWidget,
  buildCollateralBreakdownWidget,
  buildComparableLpWidget,
  buildFeeVsInterestWidget,
  buildLiquidationBoundaryWidget,
  buildRiskSummaryWidget,
  buildStressTilesWidget,
} from "../../convex/lib/askAI/widgets"

const input: PositionSnapshotInput = {
  positionId: "pos_1",
  product: "borrow",
  collateralValueUsd: 10_000,
  debtValueUsd: 4_000,
  maxLtvPct: 55,
  liquidationThresholdPct: 65,
  borrowApyPct: 5,
  lpFeeApr7dPct: 18.25,
  constituents: [
    { symbol: "ETH", weight: 0.5, feeApr7dPct: 20, inRange: true },
    { symbol: "USDC", weight: 0.5, feeApr7dPct: 4, inRange: true },
  ],
  lastUpdatedAt: 1_700_000_000_000,
}
const ctx = buildPositionContext(input, 1_700_000_100_000)

describe("widget builders", () => {
  it("build a discriminated risk summary from the buffer engine", () => {
    expect(buildRiskSummaryWidget(ctx)).toMatchObject({
      type: "risk_summary",
      riskLevel: "low",
    })
    expect(buildRiskSummaryWidget(ctx).healthFactor).toBeCloseTo(1.625, 10)
  })

  it("carry the borrow capacity payload", () => {
    const widget = buildBorrowCapacityWidget(ctx)
    expect(widget.type).toBe("borrow_capacity")
    expect(widget.capacity.availableUsd).toBeCloseTo(1_500, 6)
  })

  it("expose collateral legs and total", () => {
    const widget = buildCollateralBreakdownWidget(ctx)
    expect(widget.totalValueUsd).toBe(10_000)
    expect(widget.legs.map((l) => l.symbol)).toEqual(["ETH", "USDC"])
  })

  it("locate the liquidation boundary shock", () => {
    const widget = buildLiquidationBoundaryWidget(ctx)
    expect(widget.type).toBe("liquidation_boundary")
    expect(widget.boundary.liquidationPriceShockPct).toBeCloseTo(-38.4615, 3)
  })

  it("net carry fee against interest", () => {
    expect(buildCarrySummaryWidget(ctx).carry.netCarryPerDayUsd).toBeCloseTo(5 - (4_000 * 0.05) / 365, 8)
  })

  it("split fee vs interest per day", () => {
    const widget = buildFeeVsInterestWidget(ctx)
    expect(widget.feePerDayUsd).toBeCloseTo(5, 8)
    expect(widget.interestPerDayUsd).toBeCloseTo((4_000 * 0.05) / 365, 8)
  })

  it("produce a stress tile per default shock", () => {
    const widget = buildStressTilesWidget(ctx)
    expect(widget.presets.map((p) => p.priceShockPct)).toEqual([...DEFAULT_STRESS_SHOCKS_PCT])
  })

  it("rank comparable LPs best-first", () => {
    const widget = buildComparableLpWidget(ctx, [
      { id: "a", label: "A", feeApr7dPct: 8 },
      { id: "b", label: "B", feeApr7dPct: 15 },
    ])
    expect(widget.rows[0]!.id).toBe("b")
  })

  it("record the snapshot and fee window in the assumptions widget", () => {
    const widget = buildAssumptionsWidget(ctx, { provenance: "connected_wallet" })
    expect(widget).toMatchObject({
      type: "assumptions",
      snapshotId: ctx.snapshotId,
      asOf: ctx.asOf,
      feeWindowDays: FEE_WINDOW_DAYS,
      provenance: "connected_wallet",
    })
  })
})
