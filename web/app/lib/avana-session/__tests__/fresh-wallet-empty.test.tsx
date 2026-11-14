import { renderHook } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { useAvanaSession } from "@/app/lib/avana-session"
import { deserializeBorrowSystemState } from "@/app/lib/borrow-system/codec"
import { deserializeLendSystemState } from "@/app/lib/lend-system/codec"
import { deserializeMultiplySystemState } from "@/app/lib/multiply-system/codec"

// Issue #136: production reads per-wallet Convex state, so a fresh authenticated wallet
// must start with NO open positions (the shared static demo portfolio is dev-only and
// only reachable through the "demo" session source). Practice-fund wallet balances are
// intentional and are not asserted here — positions are what "empty" means for a fresh
// wallet, and they are hydrated per-wallet from Convex.
describe("fresh authenticated wallet starts empty (issue #136)", () => {
  it("seeds no borrow, lend, or multiply positions for a Convex-scoped wallet", () => {
    const wallet = "0xfeed0000000000000000000000000000000000ff"
    const { result } = renderHook(() => useAvanaSession(wallet, "convex"))
    const borrow = deserializeBorrowSystemState(result.current.borrowSessionSeed)
    const lend = deserializeLendSystemState(result.current.lendSessionSeed)
    const multiply = deserializeMultiplySystemState(result.current.multiplySessionSeed)

    expect(borrow.accounts[wallet]?.collateralPositions).toEqual([])
    expect(borrow.accounts[wallet]?.debtPositions).toEqual([])
    expect(lend.positions).toEqual({})
    expect(multiply.positions).toEqual({})
  })

  it("gives two distinct Convex wallets independent (empty) position sets", () => {
    const walletA = "0xaaaa000000000000000000000000000000000001"
    const walletB = "0xbbbb000000000000000000000000000000000002"
    const { result: a } = renderHook(() => useAvanaSession(walletA, "convex"))
    const { result: b } = renderHook(() => useAvanaSession(walletB, "convex"))

    // Fresh wallets are scoped to their own address, not a shared demo profile: neither
    // inherits the other's (or the demo's) positions.
    const borrowA = deserializeBorrowSystemState(a.current.borrowSessionSeed)
    const borrowB = deserializeBorrowSystemState(b.current.borrowSessionSeed)
    expect(borrowA.accounts[walletA]?.debtPositions).toEqual([])
    expect(borrowB.accounts[walletB]?.debtPositions).toEqual([])
    expect(borrowA.accounts[walletB]).toBeUndefined()
    expect(borrowB.accounts[walletA]).toBeUndefined()
    expect(a.current.walletId).toBe(walletA)
    expect(b.current.walletId).toBe(walletB)
  })
})
