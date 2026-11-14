import { act, renderHook, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { buildRewardsSessionSeed } from "@/app/lib/rewards-system"
import { useRewardsSession } from "@/app/lib/rewards-system/use-rewards-session"
import { writeRewardsSessionState } from "@/app/lib/rewards-system/storage"

describe("useRewardsSession", () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it("hydrates the wallet-scoped rewards session, tracks progress, and claims rewards", async () => {
    const walletId = "demo-wallet"

    const { result } = renderHook(() =>
      useRewardsSession({
        walletId,
        sessionSeed: buildRewardsSessionSeed(),
      }),
    )

    await waitFor(async () => {
      const progress = await result.current.readAdapter.readProgress(walletId)
      expect(progress.find((item) => item.taskId === "connect-wallet")?.status).toBe("claimable")
    })

    await act(async () => {
      await result.current.recordActivityEvent({
        id: "borrow-opened",
        wallet: walletId,
        product: "borrow",
        type: "borrow_opened",
        amountUsd: 2_500,
        timestamp: Date.UTC(2026, 5, 19),
      })
    })

    await waitFor(async () => {
      const progress = await result.current.readAdapter.readProgress(walletId)
      expect(progress.find((item) => item.taskId === "first-borrow")?.status).toBe("claimable")
    })

    await act(async () => {
      await result.current.claimReward("first-borrow")
    })

    await waitFor(async () => {
      const summary = await result.current.readAdapter.readRewardSummary(walletId)
      expect(summary.totalClaimedAmount).toBe(50)
    })
  })

  it("does not clobber persisted reward claims when the session remounts", async () => {
    const walletId = "demo-wallet"

    const firstMount = renderHook(() =>
      useRewardsSession({
        walletId,
        sessionSeed: buildRewardsSessionSeed(),
      }),
    )

    await waitFor(async () => {
      const progress = await firstMount.result.current.readAdapter.readProgress(walletId)
      expect(progress.find((item) => item.taskId === "connect-wallet")?.status).toBe("claimable")
    })

    await act(async () => {
      await firstMount.result.current.claimAllRewards()
    })

    await waitFor(async () => {
      const summary = await firstMount.result.current.readAdapter.readRewardSummary(walletId)
      expect(summary.totalClaimedAmount).toBe(25)
    })

    firstMount.unmount()

    const secondMount = renderHook(() =>
      useRewardsSession({
        walletId,
        sessionSeed: buildRewardsSessionSeed(),
      }),
    )

    await waitFor(async () => {
      const summary = await secondMount.result.current.readAdapter.readRewardSummary(walletId)
      expect(summary.totalClaimedAmount).toBe(25)
      expect(summary.totalClaimableAmount).toBe(0)
      const claims = await secondMount.result.current.readAdapter.readClaimHistory(walletId)
      expect(claims).toHaveLength(1)
      expect(claims.map((claim) => claim.taskId)).toEqual(["connect-wallet"])
    })
  })

  it("never lets a fresher local cache override the Convex rewards snapshot", async () => {
    const walletId = "demo-wallet"
    const remote = JSON.parse(buildRewardsSessionSeed())
    const forgedLocal = {
      ...remote,
      claims: [
        {
          claimId: "forged-local-claim",
          wallet: walletId,
          taskId: "connect-wallet",
          amount: 1_000_000,
          rewardSymbol: "AVA",
          status: "confirmed",
          syntheticTxHash: "forged-local-hash",
          claimedAt: 1,
        },
      ],
    }
    writeRewardsSessionState(walletId, forgedLocal)
    const persistRemoteState = vi.fn(async () => ({ revision: 1 }))

    const { result } = renderHook(() =>
      useRewardsSession({
        walletId,
        sessionSeed: buildRewardsSessionSeed(),
        persistState: false,
        remoteState: JSON.stringify(remote),
        remoteRevision: 0,
        persistRemoteState,
      }),
    )

    await waitFor(async () => {
      expect(result.current.hasHydratedStorage).toBe(true)
      const summary = await result.current.readAdapter.readRewardSummary(walletId)
      expect(summary.totalClaimedAmount).toBe(0)
      expect(result.current.state.claims).toHaveLength(0)
    })
  })

  it("seeds expectedRevision before the next locked save after create", async () => {
    const walletId = "0xabc0000000000000000000000000000000000001"
    const revisionsSeen: Array<number | undefined> = []
    let releaseFirst!: () => void
    const firstGate = new Promise<void>((resolve) => {
      releaseFirst = resolve
    })
    let persistCount = 0
    const persistRemoteState = vi.fn(async (args: { expectedRevision?: number }) => {
      revisionsSeen.push(args.expectedRevision)
      persistCount += 1
      if (persistCount === 1) {
        await firstGate
        return { revision: 0, stale: false }
      }
      return { revision: (args.expectedRevision ?? 0) + 1, stale: false }
    })

    const { result } = renderHook(() =>
      useRewardsSession({
        walletId,
        sessionSeed: buildRewardsSessionSeed(),
        persistState: false,
        remoteState: null,
        remoteRevision: null,
        persistRemoteState,
      }),
    )

    await waitFor(() => expect(result.current.hasHydratedStorage).toBe(true))
    await waitFor(() => expect(persistRemoteState).toHaveBeenCalledTimes(1))
    expect(revisionsSeen[0]).toBeUndefined()

    await act(async () => {
      await result.current.completeEducation()
    })

    // Second write is queued behind the lock; only runs after create returns revision 0.
    releaseFirst()

    await waitFor(() => {
      expect(revisionsSeen.length).toBeGreaterThanOrEqual(2)
      expect(revisionsSeen[1]).toBe(0)
    })
  })

  it("treats a remote row with a missing revision as expectedRevision 0", async () => {
    const walletId = "demo-wallet"
    const remote = buildRewardsSessionSeed()
    const revisionsSeen: Array<number | undefined> = []
    const persistRemoteState = vi.fn(async (args: { expectedRevision?: number }) => {
      revisionsSeen.push(args.expectedRevision)
      return { revision: (args.expectedRevision ?? 0) + 1, stale: false }
    })

    const { result } = renderHook(() =>
      useRewardsSession({
        walletId,
        sessionSeed: remote,
        persistState: false,
        remoteState: remote,
        remoteRevision: null,
        persistRemoteState,
      }),
    )

    await waitFor(() => expect(result.current.hasHydratedStorage).toBe(true))

    await act(async () => {
      await result.current.completeEducation()
    })

    await waitFor(() => {
      expect(revisionsSeen.length).toBeGreaterThanOrEqual(1)
      expect(revisionsSeen[0]).toBe(0)
    })
  })

  it("does not save without expectedRevision when persist turns on before remote loads", async () => {
    const walletId = "demo-wallet"
    const remote = buildRewardsSessionSeed()
    const persistRemoteState = vi.fn(async (args: { expectedRevision?: number }) => ({
      revision: (args.expectedRevision ?? 0) + 1,
      stale: false,
    }))

    // Non-rewards route: null remote, no persist (local hydrate only).
    const { result, rerender } = renderHook(
      ({
        remoteState,
        remoteRevision,
        persist,
      }: {
        remoteState: string | null | undefined
        remoteRevision: number | null | undefined
        persist?: typeof persistRemoteState
      }) =>
        useRewardsSession({
          walletId,
          sessionSeed: remote,
          persistState: false,
          remoteState,
          remoteRevision,
          persistRemoteState: persist,
        }),
      {
        initialProps: {
          remoteState: null as string | null | undefined,
          remoteRevision: null as number | null | undefined,
          persist: undefined as typeof persistRemoteState | undefined,
        },
      },
    )

    await waitFor(() => expect(result.current.hasHydratedStorage).toBe(true))
    await act(async () => {
      await result.current.completeEducation()
    })
    expect(persistRemoteState).not.toHaveBeenCalled()

    // Rewards route mounts: persist enabled while getState is still loading.
    rerender({ remoteState: undefined, remoteRevision: undefined, persist: persistRemoteState })
    await act(async () => {
      await Promise.resolve()
    })
    expect(persistRemoteState).not.toHaveBeenCalled()

    // Snapshot arrives — only then may writes include expectedRevision.
    rerender({ remoteState: remote, remoteRevision: 61, persist: persistRemoteState })
    await waitFor(() => expect(result.current.hasHydratedStorage).toBe(true))
    await act(async () => {
      await result.current.completeEducation()
    })
    await waitFor(() => expect(persistRemoteState).toHaveBeenCalled())
    expect(
      persistRemoteState.mock.calls.every((call) => call[0].expectedRevision === 61 || call[0].expectedRevision === 62),
    ).toBe(true)
  })
})
