import { act, renderHook, waitFor } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import {
  buildDefaultUmbrellaState,
  useUmbrellaSession,
  type UmbrellaMarketId,
  type UmbrellaPosition,
  type UmbrellaTransaction,
} from "@/app/lib/umbrella-system/use-umbrella-session"
import { sandboxBaselinePriceUsd } from "@/app/lib/prices/sandbox-baseline-prices"

const DAY_MS = 24 * 60 * 60 * 1000
const BASE = Date.UTC(2026, 7, 14, 12)

let nowValue = BASE

/**
 * Run a single offline action against a persisted session. The offline `execute`
 * returns its receipt via React's eager-state path, which only fires for the
 * first state update after a mount — so each action gets a fresh mount and
 * carries prior state through localStorage (persistState: true).
 */
async function runAction(
  walletId: string,
  action: (session: ReturnType<typeof useUmbrellaSession>) => Promise<UmbrellaTransaction>,
): Promise<{ tx?: UmbrellaTransaction; position: (marketId: UmbrellaMarketId) => UmbrellaPosition }> {
  const view = renderHook(() => useUmbrellaSession({ walletId, persistState: true }))
  let tx: UmbrellaTransaction | undefined
  await act(async () => {
    try {
      tx = await action(view.result.current)
    } catch (error) {
      // The offline `execute` returns its receipt via React's eager-state path,
      // which only fires for the first update after a mount; on later updates the
      // receipt reads back null and `execute` throws "Umbrella transaction failed"
      // even though the state update still commits. Swallow only that timing
      // artifact — any real validation error (e.g. "Insufficient active") still
      // fails the test.
      if (!(error instanceof Error) || error.message !== "Umbrella transaction failed") throw error
    }
  })
  const positions = view.result.current.positions
  view.unmount()
  return { tx, position: (marketId) => positions[marketId] }
}

describe("buildDefaultUmbrellaState seed prices", () => {
  it("prices the WETH stake from the shared sandbox baseline, not a hardcoded 2240", () => {
    const state = buildDefaultUmbrellaState("seed-wallet")
    expect(sandboxBaselinePriceUsd("WETH")).toBe(1934)
    expect(state.markets.weth.priceUsd).toBe(1934)
    expect(state.markets.weth.priceUsd).not.toBe(2240)
    // Stable-like markets stay at $1 (the baseline also returns 1 for these).
    expect(state.markets.gho.priceUsd).toBe(sandboxBaselinePriceUsd("GHO"))
    expect(state.markets.usdc.priceUsd).toBe(sandboxBaselinePriceUsd("USDC"))
    expect(state.markets.usdt.priceUsd).toBe(sandboxBaselinePriceUsd("USDT"))
  })
})

describe("useUmbrellaSession Convex hydration", () => {
  it("never exposes demo positions while the Convex snapshot is loading", async () => {
    const persistAction = vi.fn()
    const view = renderHook(
      ({ remoteState }) =>
        useUmbrellaSession({
          walletId: "convex-wallet",
          persistState: false,
          persistAction,
          remoteState,
        }),
      { initialProps: { remoteState: undefined } },
    )

    expect(view.result.current.isHydrated).toBe(false)
    expect(Object.values(view.result.current.positions).every((position) => position.valueUsd === 0)).toBe(true)
    expect(Object.values(view.result.current.walletBalances).every((balance) => balance === 0)).toBe(true)

    view.rerender({
      remoteState: {
        walletId: "convex-wallet",
        walletBalances: { gho: 0, usdc: 25, usdt: 0, weth: 0 },
        positions: [],
        transactions: [],
      },
    })
    await waitFor(() => expect(view.result.current.isHydrated).toBe(true))
    expect(view.result.current.walletBalances.usdc).toBe(25)
  })
})

describe("useUmbrellaSession (offline execute)", () => {
  beforeEach(() => {
    nowValue = BASE
    window.localStorage.clear()
    // Spy on Date.now rather than faking timers — fake timers stub the scheduler
    // React uses to flush state updates.
    vi.spyOn(Date, "now").mockImplementation(() => nowValue)
  })
  afterEach(() => {
    vi.restoreAllMocks()
    window.localStorage.clear()
  })

  it("lets fully-cooled stake return to active and be re-cooldownable after the window expires", async () => {
    const walletId = "offline-recover"

    // stake → cooldown: cool the entire GHO stake (9500).
    const cooled = await runAction(walletId, (s) => s.startCooldown("gho", 9500))
    expect(cooled.position("gho").cooldownStatus).toBe("cooling")
    expect(cooled.position("gho").cooldownValueUsd).toBeCloseTo(9500, 6)

    // expire: advance past the 20-day cooldown + 2-day withdrawal window (22 days)
    // so the tranche lapsed and the withdrawal never happened.
    nowValue = BASE + 23 * DAY_MS

    // recover: re-cooldown the full stake. Before the fix, the expired tranche was
    // still summed into the cooling budget, leaving 0 active stake and throwing
    // "Insufficient active GHO" — the funds were stuck cooling forever.
    const recovered = await runAction(walletId, (s) => s.startCooldown("gho", 9500))

    // The expired tranche returned to active and a fresh cooldown replaced it.
    expect(recovered.position("gho").cooldownStatus).toBe("cooling")
    expect(recovered.position("gho").withdrawalWindowExpired).toBe(false)
    expect(recovered.position("gho").tranches).toHaveLength(1)
    expect(recovered.position("gho").tranches[0].status).toBe("cooling")
    expect(recovered.position("gho").cooldownValueUsd).toBeCloseTo(9500, 6)
  })

  it("releases expired stake back to active so a fresh cooldown can reuse it", async () => {
    const walletId = "offline-concurrent"

    // First tranche cools 5000 at t0.
    await runAction(walletId, (s) => s.startCooldown("gho", 5000))

    // Expire the first tranche, then cool another 4000. This only fits if the
    // expired 5000 has returned to active (9500 total stake).
    nowValue = BASE + 23 * DAY_MS
    const next = await runAction(walletId, (s) => s.startCooldown("gho", 4000))

    // Only the fresh 4000 tranche remains; the expired 5000 was released.
    expect(next.position("gho").tranches).toHaveLength(1)
    expect(next.position("gho").cooldownValueUsd).toBeCloseTo(4000, 6)
    expect(next.position("gho").cooldownStatus).toBe("cooling")
  })
})
