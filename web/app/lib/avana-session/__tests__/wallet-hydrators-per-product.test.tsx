import { render } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { getFunctionName, type FunctionReference } from "convex/server"

const queryResults = new Map<string, unknown>()
const sessions = {
  borrow: { transactionHistory: [], hydrateWalletData: vi.fn() },
  lend: { transactionHistory: [], hydrateWalletData: vi.fn() },
  multiply: { transactionHistory: [], hydrateWalletData: vi.fn() },
  swap: { hydrateBalances: vi.fn() },
}

vi.mock("convex/react", () => ({
  useQuery: (ref: FunctionReference<"query">, args: unknown) =>
    args === "skip" ? undefined : queryResults.get(getFunctionName(ref)),
  useMutation: () => vi.fn(async () => undefined),
  useConvex: () => ({}),
}))
vi.mock("next/navigation", () => ({ usePathname: () => "/dashboard" }))
vi.mock("@/app/lib/avana-session/avana-sessions-provider", () => ({
  AvanaSessionsProvider: ({ children }: { children: unknown }) => children,
  useBorrowSessionContext: () => sessions.borrow,
  useLendSessionContext: () => sessions.lend,
  useMultiplySessionContext: () => sessions.multiply,
  useSwapSessionContext: () => sessions.swap,
}))

import { api } from "@/convex/_generated/api"
import { ConvexWalletHydrators } from "@/app/lib/avana-session/convex-avana-sessions-provider"
import { resolveProductRuntimeScope } from "@/app/lib/avana-session/product-runtime-scope"

const liquid = [{ assetId: "usdc", symbol: "USDC", amount: 100, valueUsd: 100 }]
const lend = [
  { marketId: "usdc", assetId: "usdc", symbol: "USDC", amount: 5, valueUsd: 5, state: "deposited", updatedAt: 1 },
]
const multiply = [
  { marketId: "aave-gho", assetId: "aave", symbol: "AAVE", amount: 1, valueUsd: 100, state: "position" },
]
const borrowAt = (valueUsd: number) => [
  { marketId: "eth-usdc", assetId: "lp", poolId: "eth-usdc", symbol: "LP", amount: 1, valueUsd, state: "collateral" },
]

function setBalances(borrowValueUsd: number) {
  // A fresh object each time, as Convex returns on every result.
  queryResults.set(getFunctionName(api.wallet.productBalances.listForWallet), {
    liquid: liquid.map((row) => ({ ...row })),
    borrow: borrowAt(borrowValueUsd),
    lend: lend.map((row) => ({ ...row })),
    multiply: multiply.map((row) => ({ ...row })),
  })
}

describe("ConvexWalletHydrators", () => {
  beforeEach(() => {
    queryResults.clear()
    for (const session of [sessions.borrow, sessions.lend, sessions.multiply]) session.hydrateWalletData.mockClear()
    const balances = { positions: [], balances: [] }
    queryResults.set(getFunctionName(api.sandbox.transactions.getSessionBalances), balances)
    queryResults.set(getFunctionName(api.sandbox.transactions.getSessionTransactions), [])
  })

  it("rehydrates only the borrow session when only borrow rows change (10-minute LP reprice)", () => {
    const scope = resolveProductRuntimeScope("/dashboard")
    const onWalletHydrated = vi.fn()
    setBalances(1_000)
    const { rerender } = render(
      <ConvexWalletHydrators walletId="0xabc" scope={scope} onWalletHydrated={onWalletHydrated} />,
    )
    expect(sessions.borrow.hydrateWalletData).toHaveBeenCalledTimes(1)
    expect(sessions.lend.hydrateWalletData).toHaveBeenCalledTimes(1)
    expect(sessions.multiply.hydrateWalletData).toHaveBeenCalledTimes(1)

    setBalances(1_001.37)
    rerender(<ConvexWalletHydrators walletId="0xabc" scope={scope} onWalletHydrated={onWalletHydrated} />)

    expect(sessions.borrow.hydrateWalletData).toHaveBeenCalledTimes(2)
    expect(sessions.borrow.hydrateWalletData.mock.lastCall?.[0].borrowBalances[0].valueUsd).toBe(1_001.37)
    expect(sessions.lend.hydrateWalletData).toHaveBeenCalledTimes(1)
    expect(sessions.multiply.hydrateWalletData).toHaveBeenCalledTimes(1)
  })
})
