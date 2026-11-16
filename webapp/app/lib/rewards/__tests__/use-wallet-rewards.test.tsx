import { renderHook } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

const { useQuery } = vi.hoisted(() => ({ useQuery: vi.fn((..._args: unknown[]) => undefined as unknown) }))
vi.mock("convex/react", () => ({ useQuery }))
vi.mock("@/app/lib/convex/has-convex-client", () => ({ hasConvexClient: true }))

import { useWalletRewards } from "@/app/lib/rewards/use-wallet-rewards"

const wallet = "0x00000000000000000000000000000000000000aa"
afterEach(() => useQuery.mockReset())

describe("wallet reward points", () => {
  it("reads nothing for a guest id and answers zero", () => {
    const { result } = renderHook(() => useWalletRewards("guest-1"))
    expect(result.current).toEqual({ earnedPoints: 0, completedQuests: new Set() })
    expect(useQuery.mock.calls.every((c) => c[1] === "skip")).toBe(true)
  })

  it("is undefined while loading, then carries the points and the completed quests", () => {
    expect(renderHook(() => useWalletRewards(wallet)).result.current).toBeUndefined()
    expect(useQuery.mock.calls[0]![1]).toEqual({ wallet })
    useQuery.mockReturnValue({ earnedPoints: 257, completedQuests: ["first-borrow"] })
    expect(renderHook(() => useWalletRewards(wallet)).result.current).toEqual({
      earnedPoints: 257,
      completedQuests: new Set(["first-borrow"]),
    })
  })
})
