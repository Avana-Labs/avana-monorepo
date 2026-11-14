import { describe, expect, it } from "vitest"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { buildPortfolioBorrowData, buildWalletReadSnapshot } from "@/app/lib/borrow-system/read-model"

const DAY_MS = 24 * 60 * 60 * 1000

describe("borrow read-model accrues to 'now' on read (live HF between actions)", () => {
  it("portfolio snapshot: debt grows and HF drops between two reads with no action in between", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const t0 = state.now
    const later = t0 + 30 * DAY_MS

    const atOpen = buildPortfolioBorrowData(state, "demo-wallet", t0)
    const atLater = buildPortfolioBorrowData(state, "demo-wallet", later)

    // Outstanding debt is present so interest can accrue.
    expect(atOpen.creditLines.totalBorrowedUsd).toBeGreaterThan(0)

    // Interest accrued between the two reads — no borrow/repay action ran in between.
    expect(atLater.creditLines.totalBorrowedUsd).toBeGreaterThan(atOpen.creditLines.totalBorrowedUsd)

    // Health factor drifts DOWN as debt grows against the same collateral.
    expect(atOpen.creditLines.averageHealthFactor).not.toBeNull()
    expect(atLater.creditLines.averageHealthFactor).not.toBeNull()
    expect(atLater.creditLines.averageHealthFactor as number).toBeLessThan(
      atOpen.creditLines.averageHealthFactor as number,
    )
  })

  it("does not mutate the shared state and no-ops when now <= state.now", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const t0 = state.now

    const frozen = buildPortfolioBorrowData(state, "demo-wallet", t0)
    // Reading again at the SAME t0 (or earlier) yields identical figures — accrual is
    // immutable and idempotent, so the caller's state object is never advanced in place.
    const frozenAgain = buildPortfolioBorrowData(state, "demo-wallet", t0 - DAY_MS)

    expect(state.now).toBe(t0)
    expect(frozenAgain.creditLines.totalBorrowedUsd).toBeCloseTo(frozen.creditLines.totalBorrowedUsd, 6)
    expect(frozenAgain.creditLines.averageHealthFactor as number).toBeCloseTo(
      frozen.creditLines.averageHealthFactor as number,
      6,
    )
  })

  it("wallet read snapshot: displayed HF wad drifts down with interest", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const t0 = state.now
    const later = t0 + 30 * DAY_MS

    const atOpen = buildWalletReadSnapshot(state, "demo-wallet", undefined, t0)
    const atLater = buildWalletReadSnapshot(state, "demo-wallet", undefined, later)

    expect(atOpen.creditSnapshot.totalBorrowedUsd6).toBeGreaterThan(0n)
    expect(atLater.creditSnapshot.totalBorrowedUsd6).toBeGreaterThan(atOpen.creditSnapshot.totalBorrowedUsd6)
    expect(atLater.creditSnapshot.healthFactorWad).toBeLessThan(atOpen.creditSnapshot.healthFactorWad)
  })
})
