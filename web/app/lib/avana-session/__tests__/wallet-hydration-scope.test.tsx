import { act, renderHook } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { useWalletHydrationScope } from "@/app/lib/avana-session/convex-avana-sessions-provider"

describe("useWalletHydrationScope", () => {
  it("gates a switched wallet immediately and isolates its revision map", () => {
    const { result, rerender } = renderHook(({ walletId }) => useWalletHydrationScope(walletId), {
      initialProps: { walletId: "0xaaa" },
    })

    const staleWalletCallback = result.current.handleWalletHydrated
    act(() => {
      result.current.handleWalletHydrated([{ product: "borrow", marketSlug: "eth", revision: 7 }])
    })
    const firstWalletRevisions = result.current.revisions
    expect(result.current.walletHydrationPending).toBe(false)
    expect(firstWalletRevisions.get("borrow:eth")).toBe(7)

    rerender({ walletId: "0xbbb" })

    expect(result.current.walletHydrationPending).toBe(true)
    expect(result.current.revisions).not.toBe(firstWalletRevisions)
    expect(result.current.revisions.size).toBe(0)

    act(() => {
      staleWalletCallback([{ product: "borrow", marketSlug: "eth", revision: 8 }])
    })
    expect(result.current.walletHydrationPending).toBe(true)
    expect(result.current.revisions.size).toBe(0)

    act(() => {
      result.current.handleWalletHydrated([{ product: "lend", marketSlug: "usdc", revision: 2 }])
    })
    expect(result.current.walletHydrationPending).toBe(false)
    expect(result.current.revisions.get("lend:usdc")).toBe(2)
  })
})
