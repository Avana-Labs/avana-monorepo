import { useState } from "react"
import { act, render } from "@testing-library/react"
import { beforeEach, describe, expect, it } from "vitest"
import {
  AvanaSessionsProvider,
  useAvanaIdentity,
  useAvanaSessions,
  useBorrowSessionContext,
  useLendSessionContext,
  useMultiplySessionContext,
  useRewardsSessionContext,
  useSwapSessionContext,
  useUmbrellaSessionContext,
} from "@/app/lib/avana-session/avana-sessions-provider"
import { pendingUmbrellaPersistAction } from "@/app/lib/umbrella-system/use-umbrella-session"

// Performance fix A1: each product session hook returned a bare object literal with no
// useMemo, so every AvanaSessionsProvider re-render minted new identities for all six
// session contexts (plus the derived AvanaSessions value). Any parent re-render — e.g. the
// 30s lend accrual tick — therefore re-rendered every consumer of every product.
//
// This test forces a PARENT re-render that changes none of the sessions' inputs and asserts
// each of the 8 context values is referentially stable across that re-render. Before the fix
// it fails (new identities on every render); after wrapping each hook's return in useMemo it
// passes.
describe("session render isolation (perf A1)", () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it("keeps every session context referentially stable across an inert parent re-render", async () => {
    // Captures the most recent context value seen for each of the 8 contexts.
    const latest: Record<string, unknown> = {}
    let forceParentRerender: () => void = () => {}

    function Consumers() {
      latest.avana = useAvanaSessions()
      latest.identity = useAvanaIdentity()
      latest.borrow = useBorrowSessionContext()
      latest.multiply = useMultiplySessionContext()
      latest.lend = useLendSessionContext()
      latest.rewards = useRewardsSessionContext()
      latest.swap = useSwapSessionContext()
      latest.umbrella = useUmbrellaSessionContext()
      return null
    }

    // Parent owns a counter whose bump re-renders the provider without touching any session
    // input (walletId/sessionSource are constant here).
    function Harness() {
      const [, setCount] = useState(0)
      forceParentRerender = () => setCount((c) => c + 1)
      return (
        <AvanaSessionsProvider>
          <Consumers />
        </AvanaSessionsProvider>
      )
    }

    await act(async () => {
      render(<Harness />)
    })
    // Let hydration effects settle so the "before" snapshot is the steady-state identities.
    await act(async () => {})

    const before = { ...latest }

    await act(async () => {
      forceParentRerender()
    })

    const after = { ...latest }

    for (const key of Object.keys(before)) {
      expect(after[key], `${key} context identity should be stable across an inert parent re-render`).toBe(before[key])
    }
  })

  it("keeps every wallet-backed session unhydrated while authoritative Convex reads are pending", async () => {
    const hydrated: Record<string, boolean | undefined> = {}

    function Consumers() {
      hydrated.borrow = useBorrowSessionContext().isHydrated
      hydrated.lend = useLendSessionContext().isHydrated
      hydrated.multiply = useMultiplySessionContext().isHydrated
      hydrated.swap = useSwapSessionContext().isHydrated
      hydrated.umbrella = useUmbrellaSessionContext().isHydrated
      hydrated.rewards = useRewardsSessionContext().hasHydratedStorage
      return null
    }

    await act(async () => {
      render(
        <AvanaSessionsProvider
          walletId="0xfeed000000000000000000000000000000000001"
          persistLocalState={false}
          persistUmbrellaState={false}
          sessionSource="convex"
          authoritativeWalletPending
          // Umbrella is decoupled from authoritativeWalletPending — it gates on its
          // OWN Convex query instead. Production always supplies a persist action, so
          // pass one here: with no remote snapshot yet, umbrella reads as unhydrated
          // (skeleton), matching the other sessions' pending state.
          persistUmbrellaAction={pendingUmbrellaPersistAction}
        >
          <Consumers />
        </AvanaSessionsProvider>,
      )
    })

    expect(hydrated).toEqual({
      borrow: false,
      lend: false,
      multiply: false,
      rewards: false,
      swap: false,
      umbrella: false,
    })
  })
})
