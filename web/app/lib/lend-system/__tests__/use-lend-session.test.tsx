import { act, renderHook, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it } from "vitest"
import { buildLendSessionSeed } from "@/app/lib/lend-system/demo-session"
import { writeLendSessionState } from "@/app/lib/lend-system/storage"
import { buildMockLendSystemStateWithSeedPosition } from "@/app/lib/lend-system/mock"
import { ProductionLendReadAdapter } from "@/app/lib/lend-system/production-read-adapter"
import { ProductionLendTransactionAdapter } from "@/app/lib/lend-system/production-transaction-adapter"
import { deserializeLendSystemState } from "@/app/lib/lend-system/codec"
import { useLendSession } from "@/app/lib/lend-system/use-lend-session"
import type {
  LendSandboxActionResult,
  LendTransactionAdapter,
  LendTransactionIntent,
} from "@/app/lib/lend-system/contracts"

describe("useLendSession", () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it("hydrates persisted lend state and executes a simulated deposit", async () => {
    const walletId = "demo-wallet"
    const seededState = buildMockLendSystemStateWithSeedPosition(walletId)
    seededState.walletBalances[walletId] = {
      ...(seededState.walletBalances[walletId] ?? {}),
      gho: 5_000,
    }
    const sessionSeed = buildLendSessionSeed(walletId)

    writeLendSessionState(walletId, seededState)

    const { result } = renderHook(() =>
      useLendSession({
        walletId,
        sessionSeed,
      }),
    )

    expect(Object.keys(result.current.state.positions).length).toBeGreaterThan(0)

    await act(async () => {
      const intent = result.current.createIntent({
        type: "deposit",
        walletId,
        marketId: "gho",
        depositAmount: 500,
        walletBalance: 5000,
      })
      const preview = await result.current.previewTransaction(intent)
      expect(preview.allowed).toBe(true)
      await result.current.executeTransaction(intent)
    })

    expect(result.current.transactionHistory.length).toBeGreaterThan(0)
  })

  it("updates wallet balances after deposit and withdraw", async () => {
    const walletId = "demo-wallet"
    const seededState = buildMockLendSystemStateWithSeedPosition(walletId)
    const sessionSeed = buildLendSessionSeed(walletId)

    writeLendSessionState(walletId, seededState)

    const { result } = renderHook(() =>
      useLendSession({
        walletId,
        sessionSeed,
      }),
    )

    const beforeBalance = result.current.state.walletBalances[walletId]?.eth ?? 0

    await act(async () => {
      const depositIntent = result.current.createIntent({
        type: "deposit",
        walletId,
        marketId: "eth",
        depositAmount: 1,
        walletBalance: beforeBalance,
      })
      await result.current.executeTransaction(depositIntent)
    })

    expect(result.current.state.walletBalances[walletId]?.eth).toBeCloseTo(beforeBalance - 1, 6)

    const positionId = Object.keys(result.current.state.positions).find((id) => id.includes(":eth"))!

    await act(async () => {
      const withdrawIntent = result.current.createIntent({
        type: "withdraw",
        walletId,
        marketId: "eth",
        positionId,
        withdrawAmount: 0.5,
      })
      await result.current.executeTransaction(withdrawIntent)
    })

    expect(result.current.state.walletBalances[walletId]?.eth).toBeCloseTo(beforeBalance - 0.5, 6)
  })

  it("hydrates a lend position's supplied tokens from the deposited ledger, not USD at today's price", () => {
    const walletId = "convex-wallet"
    const sessionSeed = buildLendSessionSeed(walletId)
    const { result } = renderHook(() => useLendSession({ walletId, sessionSeed }))
    const marketId = Object.keys(result.current.state.markets).find(
      (id) => (result.current.state.markets[id]?.assetPriceUsd ?? 0) > 10,
    )!
    const priceUsd = result.current.state.markets[marketId]!.assetPriceUsd

    act(() => {
      result.current.hydrateWalletData({
        balances: [],
        lendBalances: [{ marketId, assetId: marketId, symbol: "X", amount: 7, valueUsd: 37_500, state: "deposited" }],
        positions: [
          {
            _id: "p1",
            product: "lend",
            marketSlug: marketId,
            status: "open",
            suppliedUsd6: "37500000000",
            earnedUsd6: "0",
            openedAt: 1,
            lastUpdatedAt: 1,
          },
        ],
        transactions: [],
      })
    })

    const position = result.current.state.positions.p1
    expect(position?.currentSuppliedAmount).toBe(7)
    expect(position?.suppliedValueUsd).toBeCloseTo(7 * priceUsd, 6)
  })

  it("hydrates depositable wallet assets from the canonical liquid balance rows", () => {
    const walletId = "convex-wallet"
    const sessionSeed = buildLendSessionSeed(walletId)
    const { result } = renderHook(() =>
      useLendSession({
        walletId,
        sessionSeed,
      }),
    )

    act(() => {
      result.current.hydrateWalletData({
        balances: [
          { assetId: "eth", amount: 6.463, valueUsd: 15_556.86 },
          { assetId: "usdc", amount: 12_500, valueUsd: 12_496.29 },
          { assetId: "gho", amount: 12_513, valueUsd: 12_494.52 },
        ],
        lendBalances: [
          {
            marketId: "gho",
            assetId: "gho",
            symbol: "GHO",
            amount: 2.996,
            valueUsd: 2.99,
            state: "available",
          },
        ],
        positions: [],
        transactions: [],
      })
    })

    expect(result.current.state.walletBalances[walletId]).toMatchObject({
      eth: 6.463,
      usdc: 12_500,
      gho: 12_513,
    })
  })

  it("disables sandbox persistence automatically for injected production adapters", async () => {
    const walletId = "demo-wallet"
    const state = buildMockLendSystemStateWithSeedPosition(walletId)
    const sessionSeed = buildLendSessionSeed(walletId)
    const readAdapter = new ProductionLendReadAdapter({
      readMarkets: async () => Object.values(state.markets),
      readLendPage: async () => ({}) as never,
      readPortfolioLend: async () => ({}) as never,
      readWalletSnapshot: async () => ({}) as never,
    })
    const preview = {
      intent: {
        id: "intent-live",
        actionType: "claim" as const,
        walletId,
        marketId: "rewards",
        requestedAt: 123,
        simulated: false,
        payload: {
          type: "claim" as const,
          walletId,
        },
      },
      allowed: true,
      warnings: [],
      validationErrors: [],
      before: {
        suppliedAmount: 10,
        suppliedValueUsd: 100,
        principalAmount: 9,
        interestEarned: 1,
        rewardsEarnedUsd: 12,
        totalEarnedUsd: 13,
        currentApy: 0.08,
      },
      after: {
        suppliedAmount: 10,
        suppliedValueUsd: 100,
        principalAmount: 9,
        interestEarned: 1,
        rewardsEarnedUsd: 0,
        totalEarnedUsd: 1,
        currentApy: 0.08,
      },
    }
    const transactionAdapter = new ProductionLendTransactionAdapter({
      now: () => 123,
      generateId: () => "intent-live",
      previewTransaction: async () => preview,
      executeTransaction: async () => ({
        preview,
        receipt: {
          id: "tx-live",
          hash: "0xlive",
          status: "success",
          actionType: "claim",
          simulated: false,
          timestamp: 456,
        },
        historyItem: {
          id: "tx-live",
          intentId: "intent-live",
          walletId,
          marketId: "rewards",
          kind: "claim",
          status: "success",
          asset: "Rewards",
          amount: 12,
          simulated: false,
          timestamp: 456,
          hash: "0xlive",
        },
        state: {
          ...state,
          now: 456,
        },
      }),
    })

    const { result } = renderHook(() =>
      useLendSession({
        walletId,
        sessionSeed,
        readAdapter,
        transactionAdapter,
      }),
    )

    expect(result.current.readAdapter).toBe(readAdapter)
    expect(window.localStorage.length).toBe(0)

    await act(async () => {
      const intent = result.current.createIntent({
        type: "claim",
        walletId,
      })
      expect(intent.simulated).toBe(false)
      await result.current.executeTransaction(intent)
    })

    expect(result.current.transactionHistory[0]?.kind).toBe("claim")
    expect(result.current.state.now).toBe(456)
    expect(window.localStorage.length).toBe(0)
  })

  it("exposes a real isPending signal during execution (issue #142)", async () => {
    const walletId = "demo-wallet"
    const sessionSeed = buildLendSessionSeed(walletId)

    // Deferred adapter so the pending render is observable before execute resolves.
    let resolveExecute: (result: LendSandboxActionResult) => void = () => {}
    const executeResult = {
      preview: { allowed: true } as LendSandboxActionResult["preview"],
      receipt: {} as LendSandboxActionResult["receipt"],
      historyItem: {} as LendSandboxActionResult["historyItem"],
      state: deserializeLendSystemState(sessionSeed),
    } as LendSandboxActionResult
    const transactionAdapter: LendTransactionAdapter = {
      mode: "sandbox",
      createIntent: () => ({ id: "intent-pending" }) as unknown as LendTransactionIntent,
      previewTransaction: async () => ({ allowed: true }) as never,
      executeTransaction: () => new Promise((resolve) => (resolveExecute = resolve)),
    }

    const { result } = renderHook(() => useLendSession({ walletId, sessionSeed, transactionAdapter }))
    expect(result.current.isPending).toBe(false)

    act(() => {
      void result.current.executeTransaction(result.current.createIntent({ type: "claim", walletId }))
    })

    await waitFor(() => expect(result.current.isPending).toBe(true))

    await act(async () => {
      resolveExecute(executeResult)
    })

    await waitFor(() => expect(result.current.isPending).toBe(false))
  })

  it("ignores a cross-tab storage echo of its own state (no reload ping-pong, issue #142)", async () => {
    const walletId = "demo-wallet"
    const seededState = buildMockLendSystemStateWithSeedPosition(walletId)
    const sessionSeed = buildLendSessionSeed(walletId)
    writeLendSessionState(walletId, seededState)

    const { result } = renderHook(() => useLendSession({ walletId, sessionSeed }))
    // Let the restore + persist effects settle.
    await waitFor(() => expect(Object.keys(result.current.state.positions).length).toBeGreaterThan(0))

    const stateBefore = result.current.state
    // A "storage" event fires cross-tab whenever ANOTHER tab writes. Simulate another tab
    // echoing back the identical state this tab already holds. The handler re-reads from
    // localStorage (which is unchanged), so only the key on the event matters here.
    const stateKey = [...Array(window.localStorage.length).keys()]
      .map((i) => window.localStorage.key(i))
      .find((k): k is string => Boolean(k?.endsWith(`:${walletId}`)))
    act(() => {
      const storageEvent = new Event("storage")
      Object.defineProperty(storageEvent, "key", { value: stateKey })
      window.dispatchEvent(storageEvent)
    })

    // Because the incoming content matches, reloadFromStorage bails before setState — the
    // state reference is preserved, so no re-render → no re-persist → no bounce to the
    // other tab. (A regression would replace the reference on every 30s echo.)
    expect(result.current.state).toBe(stateBefore)
  })

  it("hydrates legacy lend state that is missing wallet balances", () => {
    const legacy = JSON.stringify({
      now: 123,
      markets: {},
      positions: {},
      transactions: [],
    })

    expect(deserializeLendSystemState(legacy)).toEqual({
      now: 123,
      markets: {},
      positions: {},
      walletBalances: {},
      transactions: [],
    })
  })
})
