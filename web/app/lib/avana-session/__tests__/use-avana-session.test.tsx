import { renderHook } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { buildBorrowSessionSeed } from "@/app/lib/borrow-system/demo-session"
import { useAvanaSession } from "@/app/lib/avana-session"
import { buildLendSessionSeed } from "@/app/lib/lend-system/demo-session"
import { buildMultiplySessionSeed } from "@/app/lib/multiply-system/demo-session"
import { buildRewardsSessionSeed } from "@/app/lib/rewards-system"
import { deserializeBorrowSystemState } from "@/app/lib/borrow-system/codec"
import { deserializeLendSystemState } from "@/app/lib/lend-system/codec"
import { deserializeMultiplySystemState } from "@/app/lib/multiply-system/codec"

describe("useAvanaSession", () => {
  it("returns shared wallet identity and independent product session seeds", () => {
    const { result } = renderHook(() => useAvanaSession("demo-wallet"))

    expect(result.current.walletId).toBe("demo-wallet")
    expect(result.current.walletAddress).toMatch(/^0x/i)
    expect(result.current.sandboxMode).toBe(true)
    expect(result.current.borrowSessionSeed).toBe(buildBorrowSessionSeed("demo-wallet"))
    expect(result.current.multiplySessionSeed).toBe(buildMultiplySessionSeed("demo-wallet"))
    expect(result.current.lendSessionSeed).toBe(buildLendSessionSeed("demo-wallet"))
    expect(result.current.rewardsSessionSeed).toBe(buildRewardsSessionSeed())
    expect(result.current.borrowSessionSeed).not.toBe(result.current.multiplySessionSeed)
    expect(result.current.borrowSessionSeed).not.toBe(result.current.lendSessionSeed)
  })

  it("does not seed authenticated Convex sessions with demo positions", () => {
    const wallet = "0xabc0000000000000000000000000000000000001"
    const { result } = renderHook(() => useAvanaSession(wallet, "convex"))
    const borrow = deserializeBorrowSystemState(result.current.borrowSessionSeed)
    const lend = deserializeLendSystemState(result.current.lendSessionSeed)
    const multiply = deserializeMultiplySystemState(result.current.multiplySessionSeed)

    // No demo POSITIONS may leak into an authed session — real positions hydrate from Convex.
    expect(borrow.accounts[wallet]?.walletBalanceUsd6).toBe(0n)
    expect(borrow.accounts[wallet]?.collateralPositions).toEqual([])
    expect(borrow.accounts[wallet]?.debtPositions).toEqual([])
    expect(lend.positions).toEqual({})
    expect(multiply.positions).toEqual({})

    // Product balances hydrate from Convex onboarding buckets. The frontend seed is only
    // the empty/base engine shell and must not mint practice funds locally.
    const lendHoldings = lend.walletBalances[wallet] ?? {}
    expect(lendHoldings).toEqual({})
    expect(borrow.accounts[wallet]?.walletLpBalancesUsd6).toEqual({})
  })
})
