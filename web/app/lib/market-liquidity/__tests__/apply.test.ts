import { describe, expect, it } from "vitest"
import {
  applyBorrowableAssetDelta,
  applyBorrowableAssetLiquidity,
  type DeltaMap,
} from "@/app/lib/market-liquidity/apply"

const baseAsset = {
  id: "uni-v3-bluechip:USDC",
  totalBorrowedUsd: 400,
  availableUsd: 600,
  utilization: 40,
}

describe("market-liquidity apply helpers", () => {
  it("moves available → borrowed when a borrow delta is layered on", () => {
    const next = applyBorrowableAssetLiquidity(baseAsset, { borrowedDeltaUsd: 100, suppliedDeltaUsd: 0 })
    expect(next.totalBorrowedUsd).toBe(500)
    expect(next.availableUsd).toBe(500)
    // total liquidity (1000) conserved, utilization recomputed: 500/1000 = 50%
    expect(next.utilization).toBe(50)
  })

  it("moves borrowed → available when a repay (negative) delta is layered on", () => {
    const next = applyBorrowableAssetLiquidity(baseAsset, { borrowedDeltaUsd: -200, suppliedDeltaUsd: 0 })
    expect(next.totalBorrowedUsd).toBe(200)
    expect(next.availableUsd).toBe(800)
    expect(next.utilization).toBe(20)
  })

  it("clamps at zero and is a no-op without a borrowed delta", () => {
    expect(applyBorrowableAssetLiquidity(baseAsset, undefined)).toBe(baseAsset)
    expect(applyBorrowableAssetLiquidity(baseAsset, { borrowedDeltaUsd: 0, suppliedDeltaUsd: 999 })).toBe(baseAsset)
    const overRepaid = applyBorrowableAssetLiquidity(baseAsset, { borrowedDeltaUsd: -10_000, suppliedDeltaUsd: 0 })
    expect(overRepaid.totalBorrowedUsd).toBe(0)
  })

  it("looks the delta up by asset id", () => {
    const deltas: DeltaMap = new Map([[baseAsset.id, { borrowedDeltaUsd: 100, suppliedDeltaUsd: 0 }]])
    const next = applyBorrowableAssetDelta(baseAsset, deltas)
    expect(next.availableUsd).toBe(500)
    // unknown id → unchanged
    expect(applyBorrowableAssetDelta({ ...baseAsset, id: "other" }, deltas).availableUsd).toBe(600)
  })
})
