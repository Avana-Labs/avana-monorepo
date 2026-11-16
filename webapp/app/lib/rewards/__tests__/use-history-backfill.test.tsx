import { renderHook } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"

const { run } = vi.hoisted(() => ({ run: vi.fn(async (..._args: unknown[]) => ({ status: "done" })) }))
vi.mock("convex/react", () => ({ useAction: () => run }))
vi.mock("@/app/lib/convex/has-convex-client", () => ({ hasConvexClient: true }))

import { useHistoryBackfill } from "@/app/lib/rewards/use-history-backfill"
import type { WalletRewards } from "@/app/lib/rewards/use-wallet-rewards"

const WALLET = "0x00000000000000000000000000000000000000Aa"
const rewards = (historyChecked: boolean): WalletRewards => ({
  earnedPoints: 0,
  completedQuests: new Set(),
  historyChecked,
})

beforeEach(() => run.mockClear())

describe("history backfill trigger", () => {
  it("reads the history once when it has not been read, for the lower-case wallet", () => {
    const { rerender } = renderHook(({ r }) => useHistoryBackfill(WALLET, r), { initialProps: { r: rewards(false) } })
    rerender({ r: rewards(false) })
    expect(run).toHaveBeenCalledTimes(1)
    expect(run.mock.calls[0]![0]).toEqual({ wallet: WALLET.toLowerCase() })
  })

  it("does nothing while the rewards load, once the history was read, or for a guest id", () => {
    renderHook(() => useHistoryBackfill(WALLET, undefined))
    renderHook(() => useHistoryBackfill(WALLET, rewards(true)))
    renderHook(() => useHistoryBackfill("guest-1", rewards(false)))
    renderHook(() => useHistoryBackfill(null, rewards(false)))
    expect(run).not.toHaveBeenCalled()
  })

  it("ignores a failing read", () => {
    run.mockRejectedValueOnce(new Error("down"))
    expect(() => renderHook(() => useHistoryBackfill(WALLET, rewards(false)))).not.toThrow()
  })
})
