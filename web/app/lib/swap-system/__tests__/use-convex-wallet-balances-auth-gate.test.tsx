import { renderHook } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

const { useQuery, auth } = vi.hoisted(() => ({
  useQuery: vi.fn(() => undefined),
  auth: { isAuthenticated: false },
}))
vi.mock("convex/react", () => ({ useQuery, useConvexAuth: () => auth }))

import {
  useConvexClaimBasis,
  useConvexProductWalletBalances,
  useConvexWalletOnboardingSummary,
} from "@/app/lib/swap-system/use-convex-wallet-balances"

afterEach(() => {
  useQuery.mockClear()
  auth.isAuthenticated = false
})

describe("auth-gated wallet reads", () => {
  // These queries call requireSandboxWallet, which throws when unauthenticated — and useQuery
  // re-throws into render, which crashed the dashboard before the JWT was attached.
  it("skips every wallet query until Convex has authenticated", () => {
    renderHook(() => {
      useConvexProductWalletBalances("0xabc")
      useConvexClaimBasis("0xabc")
      useConvexWalletOnboardingSummary("0xabc")
    })
    expect(useQuery).toHaveBeenCalledTimes(3)
    for (const call of useQuery.mock.calls as unknown as Array<[unknown, unknown]>) expect(call[1]).toBe("skip")
  })

  it("subscribes with the wallet once authenticated", () => {
    auth.isAuthenticated = true
    renderHook(() => useConvexProductWalletBalances("0xabc"))
    expect((useQuery.mock.calls as unknown as Array<[unknown, unknown]>)[0]?.[1]).toEqual({ wallet: "0xabc" })
  })
})
