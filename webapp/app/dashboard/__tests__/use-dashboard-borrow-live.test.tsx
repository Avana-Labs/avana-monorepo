import { renderHook, waitFor } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { useDashboardBorrowLive } from "@/app/dashboard/use-dashboard-borrow-live"

describe("useDashboardBorrowLive", () => {
  it("re-reads portfolio borrow when session state or transaction history changes", async () => {
    const readPortfolioBorrow = vi
      .fn()
      .mockResolvedValueOnce({
        creditLines: {
          approvedUsd: 100,
          liquidationThresholdUsd: 80,
          averageHealthFactor: 2,
          currentLtvPct: 40,
          totalBorrowedUsd: 50,
          totalCollateralUsd: 100,
        },
        collateralPositions: [],
        debtPositions: [],
      })
      .mockResolvedValueOnce({
        creditLines: {
          approvedUsd: 200,
          liquidationThresholdUsd: 160,
          averageHealthFactor: 2.5,
          currentLtvPct: 30,
          totalBorrowedUsd: 75,
          totalCollateralUsd: 250,
        },
        collateralPositions: [],
        debtPositions: [],
      })

    const borrowSession = {
      readAdapter: { readPortfolioBorrow },
      state: { now: 1, markets: {}, assets: {}, accounts: {}, transactions: [] },
      transactionHistory: [] as unknown[],
    }

    const { result, rerender } = renderHook(({ session }) => useDashboardBorrowLive("demo-wallet", session), {
      initialProps: { session: borrowSession },
    })

    await waitFor(() => expect(result.current?.creditLines.approvedUsd).toBe(100))
    expect(readPortfolioBorrow).toHaveBeenCalledTimes(1)

    rerender({
      session: {
        ...borrowSession,
        transactionHistory: [{ id: "tx-1" }],
      },
    })

    await waitFor(() => expect(result.current?.creditLines.approvedUsd).toBe(200))
    expect(readPortfolioBorrow).toHaveBeenCalledTimes(2)
  })

  it("returns refreshed debt position rows after session history updates", async () => {
    const readPortfolioBorrow = vi
      .fn()
      .mockResolvedValueOnce({
        creditLines: {
          approvedUsd: 100,
          liquidationThresholdUsd: 80,
          averageHealthFactor: 2,
          currentLtvPct: 40,
          totalBorrowedUsd: 50,
          totalCollateralUsd: 100,
        },
        collateralPositions: [],
        debtPositions: [
          {
            id: "debt-a",
            pool: { id: "pool-a" },
            borrowedUsd: 50,
            liquidationThresholdUsd: 0,
            healthFactor: 2,
            borrowApr: 4,
            accruedInterestUsd: 0,
            dailyInterestUsd: 0,
          },
        ],
      })
      .mockResolvedValueOnce({
        creditLines: {
          approvedUsd: 100,
          liquidationThresholdUsd: 80,
          averageHealthFactor: 1.7,
          currentLtvPct: 60,
          totalBorrowedUsd: 300,
          totalCollateralUsd: 100,
        },
        collateralPositions: [],
        debtPositions: [
          {
            id: "debt-a",
            pool: { id: "pool-a" },
            borrowedUsd: 300,
            liquidationThresholdUsd: 0,
            healthFactor: 1.7,
            borrowApr: 4,
            accruedInterestUsd: 0,
            dailyInterestUsd: 0,
          },
        ],
      })

    const borrowSession = {
      readAdapter: { readPortfolioBorrow },
      state: { now: 1, markets: {}, assets: {}, accounts: {}, transactions: [] },
      transactionHistory: [] as unknown[],
    }

    const { result, rerender } = renderHook(({ session }) => useDashboardBorrowLive("demo-wallet", session), {
      initialProps: { session: borrowSession },
    })

    await waitFor(() => expect(result.current?.debtPositions[0]?.borrowedUsd).toBe(50))

    rerender({
      session: {
        ...borrowSession,
        transactionHistory: [{ id: "borrow-tx" }],
      },
    })

    await waitFor(() => expect(result.current?.debtPositions[0]?.borrowedUsd).toBe(300))
  })
})
