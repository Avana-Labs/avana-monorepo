import { act, renderHook, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it } from "vitest"
import { AvanaSessionsProvider, useAvanaSessions } from "@/app/lib/avana-session/avana-sessions-provider"
import { buildMockLendSystemStateWithSeedPosition } from "@/app/lib/lend-system/mock"
import { writeLendSessionState } from "@/app/lib/lend-system/storage"

describe("Avana rewards bridge", () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it("turns successful lend, borrow, and multiply actions into live rewards progress", async () => {
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

    await act(async () => {
      const borrowMarketId = result.current.borrow.collateralPools[0]!.id
      const borrowAssetId = result.current.borrow.getBorrowableAssetsForMarket(borrowMarketId)[0]!.id

      const lendIntent = result.current.lend.createIntent({
        type: "deposit",
        walletId: result.current.walletId,
        marketId: "gho",
        depositAmount: 6_000,
        walletBalance: 10_000,
      })
      await result.current.lend.executeTransaction(lendIntent)

      const borrowIntent = result.current.borrow.createIntent({
        type: "borrow",
        walletId: result.current.walletId,
        marketId: borrowMarketId,
        assetId: borrowAssetId,
        amountUsd6: 2_500_000_000n,
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
      expect(progress.find((item) => item.taskId === "first-lend-deposit")?.status).toBe("claimable")
      expect(progress.find((item) => item.taskId === "first-borrow")?.status).toBe("claimable")
      expect(progress.find((item) => item.taskId === "first-multiply")?.status).toBe("claimable")
    })
  })

  it("does not misclassify lend reward claims as rewards or withdraw activity", async () => {
    const walletId = "demo-wallet"
    const seededState = buildMockLendSystemStateWithSeedPosition(walletId)
    seededState.positions[`${walletId}:eth`] = {
      ...seededState.positions[`${walletId}:eth`]!,
      rewardsEarnedUsd: 42,
    }
    writeLendSessionState(walletId, seededState)

    const wrapper = ({ children }: { children: React.ReactNode }) => (
      <AvanaSessionsProvider>{children}</AvanaSessionsProvider>
    )
    const { result } = renderHook(() => useAvanaSessions(), { wrapper })

    const eventsBeforeClaim = await result.current.rewards.readAdapter.readRecentActivity(walletId)
    const withdrawCountBeforeClaim = eventsBeforeClaim.filter((event) => event.type === "lend_withdrawn").length
    const rewardClaimCountBeforeClaim = eventsBeforeClaim.filter((event) => event.type === "reward_claimed").length

    await act(async () => {
      await result.current.lend.claimRewards()
    })

    await waitFor(() => {
      expect(result.current.lend.transactionHistory[0]?.kind).toBe("claim")
    })

    const eventsAfterClaim = await result.current.rewards.readAdapter.readRecentActivity(walletId)

    expect(eventsAfterClaim.filter((event) => event.type === "lend_withdrawn")).toHaveLength(withdrawCountBeforeClaim)
    expect(eventsAfterClaim.filter((event) => event.type === "reward_claimed")).toHaveLength(
      rewardClaimCountBeforeClaim,
    )
  })

  it("preserves claimed rewards across provider remounts", async () => {
    const wrapper = ({ children }: { children: React.ReactNode }) => (
      <AvanaSessionsProvider>{children}</AvanaSessionsProvider>
    )
    const firstMount = renderHook(() => useAvanaSessions(), { wrapper })

    await waitFor(async () => {
      const progress = await firstMount.result.current.rewards.readAdapter.readProgress(
        firstMount.result.current.walletId,
      )
      expect(progress.find((item) => item.taskId === "connect-wallet")?.status).toBe("claimable")
    })

    await act(async () => {
      await firstMount.result.current.rewards.claimAllRewards()
    })

    await waitFor(async () => {
      const summary = await firstMount.result.current.rewards.readAdapter.readRewardSummary(
        firstMount.result.current.walletId,
      )
      expect(summary.totalClaimedAmount).toBe(25)
    })

    firstMount.unmount()

    const secondMount = renderHook(() => useAvanaSessions(), { wrapper })

    await waitFor(async () => {
      const summary = await secondMount.result.current.rewards.readAdapter.readRewardSummary(
        secondMount.result.current.walletId,
      )
      expect(summary.totalClaimedAmount).toBe(25)
    })
  })
})
