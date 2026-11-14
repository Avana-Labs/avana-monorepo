import { act, renderHook } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { useEnsureWalletFixtures } from "@/app/lib/avana-session/convex-avana-sessions-provider"

describe("useEnsureWalletFixtures", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("ensures fixtures again when the authenticated wallet changes", async () => {
    const ensurePortfolioSnapshot = vi.fn(async () => undefined)
    const ensureUmbrellaFixtures = vi.fn(async () => undefined)
    const { rerender } = renderHook(
      ({ walletId }) =>
        useEnsureWalletFixtures({
          walletId,
          ensurePortfolioSnapshot,
          ensureUmbrellaFixtures,
        }),
      { initialProps: { walletId: "0xaaa" } },
    )

    await act(async () => {})
    rerender({ walletId: "0xbbb" })
    await act(async () => {})

    expect(ensurePortfolioSnapshot).toHaveBeenNthCalledWith(1, { wallet: "0xaaa" })
    expect(ensurePortfolioSnapshot).toHaveBeenNthCalledWith(2, { wallet: "0xbbb" })
    expect(ensureUmbrellaFixtures).toHaveBeenNthCalledWith(1, { wallet: "0xaaa" })
    expect(ensureUmbrellaFixtures).toHaveBeenNthCalledWith(2, { wallet: "0xbbb" })
  })

  it("retries both idempotent fixture mutations after a transient failure", async () => {
    vi.useFakeTimers()
    const ensurePortfolioSnapshot = vi.fn().mockRejectedValueOnce(new Error("offline")).mockResolvedValue(undefined)
    const ensureUmbrellaFixtures = vi.fn(async () => undefined)

    renderHook(() =>
      useEnsureWalletFixtures({
        walletId: "0xaaa",
        ensurePortfolioSnapshot,
        ensureUmbrellaFixtures,
        retryDelayMs: 10,
      }),
    )
    await act(async () => {})

    await act(async () => {
      await vi.advanceTimersByTimeAsync(10)
    })

    expect(ensurePortfolioSnapshot).toHaveBeenCalledTimes(2)
    expect(ensureUmbrellaFixtures).toHaveBeenCalledTimes(1)
    expect(ensureUmbrellaFixtures).toHaveBeenCalledWith({ wallet: "0xaaa" })
  })

  it("stops retrying when a Convex deployment remains unavailable", async () => {
    vi.useFakeTimers()
    const ensurePortfolioSnapshot = vi.fn(async () => {
      throw new Error("function not found")
    })
    const ensureUmbrellaFixtures = vi.fn(async () => undefined)

    renderHook(() =>
      useEnsureWalletFixtures({
        walletId: "0xaaa",
        ensurePortfolioSnapshot,
        ensureUmbrellaFixtures,
        retryDelayMs: 10,
        maxAttempts: 3,
      }),
    )
    await act(async () => {})

    await act(async () => {
      await vi.advanceTimersByTimeAsync(10)
    })
    await act(async () => {
      await vi.advanceTimersByTimeAsync(20)
    })

    expect(ensurePortfolioSnapshot).toHaveBeenCalledTimes(3)
    expect(ensureUmbrellaFixtures).not.toHaveBeenCalled()
    expect(vi.getTimerCount()).toBe(0)
  })
})
