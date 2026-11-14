import type { ReactNode } from "react"
import { renderHook, waitFor } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import {
  AvanaSessionsProvider,
  useBorrowSessionContext,
  useLendSessionContext,
  useMultiplySessionContext,
  useSwapSessionContext,
  useUmbrellaSessionContext,
} from "@/app/lib/avana-session/avana-sessions-provider"
import { GUEST_WALLET_ID } from "@/app/lib/data/wallet/profiles"

// A visitor with no wallet must never see the local-test demo balances on any action page.
function GuestSession({ children }: { children: ReactNode }) {
  return (
    <AvanaSessionsProvider
      walletId={GUEST_WALLET_ID}
      sessionSource="convex"
      persistLocalState={false}
      persistUmbrellaState={false}
    >
      {children}
    </AvanaSessionsProvider>
  )
}

const nonZero = (values: Record<string, number | bigint> | undefined) =>
  Object.values(values ?? {}).filter((value) => Number(value) !== 0)

describe("guest session", () => {
  it("has no balances or positions in any product", async () => {
    const { result } = renderHook(
      () => ({
        borrow: useBorrowSessionContext(),
        lend: useLendSessionContext(),
        multiply: useMultiplySessionContext(),
        swap: useSwapSessionContext(),
        umbrella: useUmbrellaSessionContext(),
      }),
      { wrapper: GuestSession },
    )
    await waitFor(() => expect(result.current.swap.isHydrated).toBe(true))
    const { borrow, lend, multiply, swap, umbrella } = result.current

    expect(swap.walletBalances.filter((balance) => balance.amount > 0)).toEqual([])

    const account = borrow.state.accounts[GUEST_WALLET_ID]
    expect(Number(account?.walletBalanceUsd6 ?? 0)).toBe(0)
    expect(nonZero(account?.walletLpBalancesUsd6)).toEqual([])
    expect(account?.collateralPositions ?? []).toEqual([])
    expect(account?.debtPositions ?? []).toEqual([])

    expect(nonZero(lend.state.walletBalances[GUEST_WALLET_ID])).toEqual([])
    expect(lend.state.positions).toEqual({})

    expect(nonZero(multiply.state.walletBalancesUsd[GUEST_WALLET_ID])).toEqual([])
    expect(multiply.state.positions).toEqual({})

    expect(nonZero(umbrella.walletBalances)).toEqual([])
    expect(Object.values(umbrella.positions ?? {}).filter((position) => position.amount > 0)).toEqual([])
  })
})
