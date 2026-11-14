import { act, renderHook, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it } from "vitest"
import { parseFixed } from "@/app/lib/borrow-system/model"
import { buildBorrowSessionSeed } from "@/app/lib/borrow-system/demo-session"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { writeBorrowSessionMetadata, writeBorrowSessionState } from "@/app/lib/borrow-system/storage"
import {
  inferPersistedDebtAssetId,
  reconcileLegacyRepayPrincipal,
  useBorrowSession,
} from "@/app/lib/borrow-system/use-borrow-session"

describe("useBorrowSession", () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it("recovers the debt asset for legacy repayment rows", () => {
    expect(
      inferPersistedDebtAssetId(
        {
          marketSlug: "aero-slipstream-bluechip-cbbtc-usdc",
          kind: "repay",
        } as never,
        [
          {
            marketSlug: "aero-slipstream-bluechip-cbbtc-usdc",
            debt: [{ assetId: "aero-slipstream-bluechip:usdc", baseAssetId: "usdc" }],
          },
        ] as never,
      ),
    ).toBe("aero-slipstream-bluechip:usdc")
  })

  it("rebuilds a legacy repay principal from the durable borrow and repay ledger", () => {
    const position = { marketSlug: "aero-slipstream-bluechip-cbbtc-usdc" } as never
    const debt = { assetId: "aero-slipstream-bluechip:usdc", baseAssetId: "usdc" } as never
    const principal = reconcileLegacyRepayPrincipal(position, debt, [
      {
        product: "borrow",
        kind: "borrow",
        marketSlug: position.marketSlug,
        assetId: debt.assetId,
        executedAmountUsd6: "1000000000",
      },
      { product: "borrow", kind: "repay", marketSlug: position.marketSlug, executedAmountUsd6: "100000000" },
    ] as never)
    expect(principal).toBe(900_000_000n)
  })

  it("hydrates from the canonical seed and persists adapter-driven deposit updates", async () => {
    const walletId = "demo-wallet"
    const seeded = buildMockBorrowSystemState(walletId)
    const { result } = renderHook(() =>
      useBorrowSession({
        walletId,
        sessionSeed: buildBorrowSessionSeed(walletId),
      }),
    )

    const initialCollateral = result.current.walletSnapshot.totalCollateralUsd

    await act(async () => {
      const transaction = await result.current.executeTransaction(
        result.current.createIntent({
          type: "supplyCollateral",
          walletId,
          marketId: "uni-v3-bluechip-weth-usdc",
          amountUsd6: parseFixed("500", 6),
          at: seeded.now + 1000,
        }),
      )

      expect(transaction.receipt.simulated).toBe(true)
    })

    expect(result.current.walletSnapshot.totalCollateralUsd).toBeGreaterThan(initialCollateral)
    expect(
      result.current.marketSummaries.find((market) => market.id === "uni-v3-bluechip-weth-usdc")?.collateralExampleUsd,
    ).toBeGreaterThan(0)
  })

  it("keeps borrow updates visible through the same wallet-scoped session", async () => {
    const walletId = "demo-wallet"
    const seeded = buildMockBorrowSystemState(walletId)
    const { result } = renderHook(() =>
      useBorrowSession({
        walletId,
        sessionSeed: buildBorrowSessionSeed(walletId),
      }),
    )

    const initialDebt = result.current.initialDebts["uni-v3-bluechip-weth-usdc"] ?? 0

    await act(async () => {
      const preview = await result.current.previewTransaction(
        result.current.createIntent({
          type: "borrow",
          walletId,
          marketId: "uni-v3-bluechip-weth-usdc",
          assetId: "uni-v3-bluechip:usdc",
          amountUsd6: parseFixed("250", 6),
          at: seeded.now + 2000,
        }),
      )

      expect(preview.allowed).toBe(true)
      await result.current.executeTransaction(preview.intent)
    })

    expect(result.current.initialDebts["uni-v3-bluechip-weth-usdc"]).toBeGreaterThan(initialDebt)
    expect(result.current.walletSnapshot.totalBorrowedUsd).toBeGreaterThan(2000)
  })

  it("does not mutate session state when previewing an invalid transaction", async () => {
    const walletId = "demo-wallet"
    const { result } = renderHook(() =>
      useBorrowSession({
        walletId,
        sessionSeed: buildBorrowSessionSeed(walletId),
      }),
    )

    const initialDebt = result.current.walletSnapshot.totalBorrowedUsd

    await act(async () => {
      const preview = await result.current.previewTransaction(
        result.current.createIntent({
          type: "borrow",
          walletId,
          marketId: "uni-v3-bluechip-weth-usdc",
          assetId: "uni-v3-bluechip:usdc",
          amountUsd6: parseFixed("50000", 6),
        }),
      )

      expect(preview.allowed).toBe(false)
      expect(preview.validationErrors.length).toBeGreaterThan(0)
    })

    expect(result.current.walletSnapshot.totalBorrowedUsd).toBe(initialDebt)
  })

  it("hydrates persisted receipts and canonical history for the current wallet session", async () => {
    const walletId = "demo-wallet"
    const seededState = buildMockBorrowSystemState(walletId)
    const sessionSeed = buildBorrowSessionSeed(walletId)

    writeBorrowSessionState(walletId, seededState)
    writeBorrowSessionMetadata(walletId, {
      transactionHistory: [
        {
          id: "history-1",
          intentId: "intent-1",
          walletId,
          marketId: "uni-v3-bluechip-weth-usdc",
          assetId: "uni-v3-bluechip:usdc",
          kind: "borrow",
          status: "success",
          requestedAmountUsd6: parseFixed("250", 6),
          executedAmountUsd6: parseFixed("250", 6),
          simulated: true,
          timestamp: seededState.now + 2_000,
          hash: "sim_1",
        },
      ],
      receipts: [
        {
          id: "receipt-1",
          hash: "sim_1",
          status: "success",
          actionType: "borrow",
          simulated: true,
          timestamp: seededState.now + 2_000,
        },
      ],
    })

    const { result } = renderHook(() =>
      useBorrowSession({
        walletId,
        sessionSeed,
      }),
    )

    expect(result.current.transactionHistory[0]?.intentId).toBe("intent-1")
    expect(result.current.lastReceipt?.hash).toBe("sim_1")

    await act(async () => {
      const snapshot = await result.current.readAdapter.readWalletSnapshot(walletId)
      expect(snapshot.transactionHistory[0]?.intentId).toBe("intent-1")
    })
  })

  it("hydrates onboarding LP collateral with the server's token count, not USD at the browser price", async () => {
    const walletId = "convex-wallet"
    const sessionSeed = buildBorrowSessionSeed(walletId)
    const { result } = renderHook(() => useBorrowSession({ walletId, sessionSeed }))
    const marketSlug = Object.values(result.current.state.markets).find(
      (market) => market.snapshot.lpTokenPriceUsd6 > 1_000_000_000n,
    )!.id

    act(() => {
      result.current.hydrateWalletData({
        balances: [],
        borrowBalances: [{ marketId: marketSlug, symbol: "LP", amount: 1.0375, valueUsd: 43_750, state: "collateral" }],
        positions: [
          {
            product: "borrow",
            marketSlug,
            lastUpdatedAt: 1,
            collateral: [
              {
                _id: "c1",
                marketSlug,
                collateralShares: "0",
                principalTokenAmount: "0",
                collateralEnabled: true,
                collateralValueUsd6: "43750000000",
              },
            ],
            debt: [],
          },
        ],
        transactions: [],
      })
    })

    await waitFor(() => {
      const leg = result.current.state.accounts[walletId].collateralPositions.find((p) => p.marketId === marketSlug)
      expect(leg?.principalTokenAmount).toBe(parseFixed("1.0375", 18))
    })
  })

  it("anchors the engine clock to the last persisted moment, not wall-clock, on hydration", async () => {
    const walletId = "convex-wallet"
    const sessionSeed = buildBorrowSessionSeed(walletId)
    const { result } = renderHook(() =>
      useBorrowSession({
        walletId,
        sessionSeed,
      }),
    )
    // The wallet's last real persisted activity (the seed's onboarding moment).
    const persistedMoment = result.current.state.accounts[walletId].lastUpdatedAt

    act(() => {
      result.current.hydrateWalletData({
        balances: [],
        borrowBalances: [],
        positions: [],
        transactions: [],
      })
    })

    // Hydration anchors the engine clock to that persisted moment instead of jumping it
    // forward to Date.now(). The read model then accrues supply/debt indices across the
    // offline gap (now → Date.now()) rather than collapsing that span to zero, so a loan
    // open for days still shows its accrued Interest Owed. See hydrateWalletData.
    await waitFor(() => {
      expect(result.current.state.now).toBe(persistedMoment)
    })
    expect(result.current.state.now).toBeLessThan(Date.now())
  })

  it("dedupes concurrent execute calls for the same intent", async () => {
    const walletId = "demo-wallet"
    const { result } = renderHook(() =>
      useBorrowSession({
        walletId,
        sessionSeed: buildBorrowSessionSeed(walletId),
      }),
    )

    const intent = result.current.createIntent({
      type: "borrow",
      walletId,
      marketId: "uni-v3-bluechip-weth-usdc",
      assetId: "uni-v3-bluechip:usdc",
      amountUsd6: parseFixed("100", 6),
    })

    const historyBefore = result.current.transactionHistory.length

    await act(async () => {
      await Promise.all([result.current.executeTransaction(intent), result.current.executeTransaction(intent)])
    })

    expect(result.current.transactionHistory.length).toBe(historyBefore + 1)
  })

  it("exposes isPending while execute is in flight", async () => {
    const walletId = "demo-wallet"
    const { result } = renderHook(() =>
      useBorrowSession({
        walletId,
        sessionSeed: buildBorrowSessionSeed(walletId),
      }),
    )

    const debtPosition = result.current.state.accounts[walletId]?.debtPositions[0]
    expect(debtPosition).toBeDefined()

    const intent = result.current.createIntent({
      type: "repay",
      walletId,
      debtPositionId: debtPosition!.id,
      amountUsd6: parseFixed("50", 6),
    })

    let execution!: ReturnType<(typeof result.current)["executeTransaction"]>
    act(() => {
      execution = result.current.executeTransaction(intent)
    })

    await waitFor(() => {
      expect(result.current.isPending).toBe(true)
    })

    await act(async () => {
      await execution
    })

    expect(result.current.isPending).toBe(false)
  })
})
