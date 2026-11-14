import { act, renderHook, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it } from "vitest"
import { parseFixed } from "@/app/lib/credit-engine"
import { AvanaSessionsProvider, useAvanaSessions } from "@/app/lib/avana-session/avana-sessions-provider"
import { buildMockLendSystemStateWithSeedPosition } from "@/app/lib/lend-system/mock"
import { writeLendSessionState } from "@/app/lib/lend-system/storage"

describe("Avana rewards product flows", () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it("tracks aggregate rewards progress from real lend, borrow, repay, multiply, and deleverage actions", async () => {
    const walletId = "demo-wallet"
    const seededLendState = buildMockLendSystemStateWithSeedPosition(walletId)
    seededLendState.walletBalances[walletId] = {
      ...(seededLendState.walletBalances[walletId] ?? {}),
      gho: 10_000,
    }
    writeLendSessionState(walletId, seededLendState)

    const wrapper = ({ children }: { children: React.ReactNode }) => (
      <AvanaSessionsProvider>{children}</AvanaSessionsProvider>
    )
    const { result } = renderHook(() => useAvanaSessions(), { wrapper })

    let borrowMarketId = ""
    let borrowAssetId = ""

    await act(async () => {
      borrowMarketId = result.current.borrow.collateralPools[0]!.id
      borrowAssetId = result.current.borrow.getBorrowableAssetsForMarket(borrowMarketId)[0]!.id

      const lendIntentA = result.current.lend.createIntent({
        type: "deposit",
        walletId: result.current.walletId,
        marketId: "gho",
        depositAmount: 200,
        walletBalance: 10_000,
      })
      await result.current.lend.executeTransaction(lendIntentA)

      const lendIntentB = result.current.lend.createIntent({
        type: "deposit",
        walletId: result.current.walletId,
        marketId: "gho",
        depositAmount: 300,
        walletBalance: 10_000,
      })
      await result.current.lend.executeTransaction(lendIntentB)

      const borrowIntent = result.current.borrow.createIntent({
        type: "borrow",
        walletId: result.current.walletId,
        marketId: borrowMarketId,
        assetId: borrowAssetId,
        amountUsd6: parseFixed("200", 6),
        at: Date.now(),
      })
      await result.current.borrow.executeTransaction(borrowIntent)

      const multiplyIntent = result.current.multiply.createIntent({
        type: "multiply",
        walletId: result.current.walletId,
        marketId: "eth-usdt",
        collateralAmount: 300,
        selectedMultiplier: 2,
      })
      await result.current.multiply.executeTransaction(multiplyIntent)
    })

    await waitFor(async () => {
      const progress = await result.current.rewards.readAdapter.readProgress(result.current.walletId)
      expect(progress.find((item) => item.taskId === "supply-5k-lend")?.status).toBe("claimable")
      expect(progress.find((item) => item.taskId === "first-lend-deposit")?.status).toBe("claimable")
      expect(progress.find((item) => item.taskId === "first-borrow")?.status).toBe("claimable")
      expect(progress.find((item) => item.taskId === "first-multiply")?.status).toBe("claimable")
    })

    await act(async () => {
      await result.current.rewards.claimReward("first-lend-deposit")
      await result.current.rewards.claimReward("first-borrow")
      await result.current.rewards.claimReward("first-multiply")
    })

    await waitFor(async () => {
      const progress = await result.current.rewards.readAdapter.readProgress(result.current.walletId)
      expect(progress.find((item) => item.taskId === "first-lend-deposit")?.status).toBe("claimed")
      expect(progress.find((item) => item.taskId === "first-borrow")?.status).toBe("claimed")
      expect(progress.find((item) => item.taskId === "first-multiply")?.status).toBe("claimed")
    })

    await act(async () => {
      const debtPositionId = result.current.borrow.state.accounts[result.current.walletId]?.debtPositions.at(-1)?.id
      expect(debtPositionId).toBeDefined()

      for (let index = 0; index < 3; index += 1) {
        const repayIntent = result.current.borrow.createIntent({
          type: "repay",
          walletId: result.current.walletId,
          debtPositionId: debtPositionId!,
          amountUsd6: parseFixed("50", 6),
        })
        await result.current.borrow.executeTransaction(repayIntent)
      }

      const multiplyPositionId = Object.values(result.current.multiply.state.positions).find(
        (position) => position.walletId === result.current.walletId,
      )?.id
      expect(multiplyPositionId).toBeDefined()

      const firstDeleverageIntent = result.current.multiply.createIntent({
        type: "deleverage",
        walletId: result.current.walletId,
        positionId: multiplyPositionId!,
        targetMultiplier: 1.8,
      })
      await result.current.multiply.executeTransaction(firstDeleverageIntent)

      const secondDeleverageIntent = result.current.multiply.createIntent({
        type: "deleverage",
        walletId: result.current.walletId,
        positionId: multiplyPositionId!,
        targetMultiplier: 1.5,
      })
      await result.current.multiply.executeTransaction(secondDeleverageIntent)
    })

    await waitFor(async () => {
      const progress = await result.current.rewards.readAdapter.readProgress(result.current.walletId)
      expect(progress.find((item) => item.taskId === "first-repay")?.status).toBe("claimable")
      expect(progress.find((item) => item.taskId === "first-deleverage")?.status).toBe("claimable")
    })

    const summary = await result.current.rewards.readAdapter.readRewardSummary(result.current.walletId)
    expect(summary.claimableTaskCount).toBeGreaterThanOrEqual(4)
    expect(summary.totalClaimableAmount).toBeGreaterThan(0)
    expect(summary.completedTaskCount).toBeGreaterThanOrEqual(7)
  })
})
