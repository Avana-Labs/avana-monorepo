import { act, renderHook, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { WalletActivityRowLike } from "../wallet-activity"

const WALLET = "0x00000000000000000000000000000000000000a1"

const paginated = vi.hoisted(() => ({
  current: { results: [] as unknown[], status: "Exhausted" as string, loadMore: vi.fn() },
}))
const older = vi.hoisted(() => vi.fn())

vi.mock("@/app/lib/convex/has-convex-client", () => ({ hasConvexClient: true }))
vi.mock("@/app/lib/avana-session/avana-sessions-context", () => ({ useBorrowSessionContextOptional: () => undefined }))
vi.mock("convex/react", () => ({
  usePaginatedQuery: () => paginated.current,
  useQuery: () => [{ chainId: 1 }, { chainId: 8453 }],
  useAction: () => older,
}))

import { useWalletActivity } from "../use-wallet-activity"

const lendRow = (id: string, over: Partial<WalletActivityRowLike> = {}): WalletActivityRowLike => ({
  id,
  at: "2026-11-16T12:00:00.000Z",
  kind: "supply",
  amountUsd: 100,
  tokenAmountLabel: "100 USDC",
  tokenSymbol: "USDC",
  txHash: "0xabc",
  chainId: 1,
  page: { scope: "lend", slug: "usdc-core" },
  ...over,
})

describe("useWalletActivity", () => {
  beforeEach(() => {
    older.mockReset()
    paginated.current = { results: [lendRow("1:0xabc:0")], status: "CanLoadMore", loadMore: vi.fn() }
  })

  it("pages the last 30 days first and reads no older history while they last", () => {
    const { result } = renderHook(() => useWalletActivity(WALLET))
    expect(result.current.hasMore).toBe(true)
    act(() => result.current.loadMore())
    expect(paginated.current.loadMore).toHaveBeenCalledWith(20)
    expect(older).not.toHaveBeenCalled()
  })

  it("reads one older page per chain on each loadMore once the last 30 days are read, until every chain is done", async () => {
    paginated.current = { results: [lendRow("1:0xabc:0")], status: "Exhausted", loadMore: vi.fn() }
    older.mockImplementation(async ({ chainId, before }: { chainId: number; before?: string }) =>
      chainId === 1
        ? before === undefined
          ? {
              status: "ok",
              next: "500",
              rows: [
                lendRow("1:0xabc:0"),
                lendRow("1:0xold:0", {
                  at: "2026-09-01T00:00:00.000Z",
                  amountUsd: undefined,
                  tokenAmountLabel: "7 USDC",
                }),
              ],
            }
          : { status: "ok", next: null, rows: [] }
        : { status: "rateLimited" },
    )
    const { result } = renderHook(() => useWalletActivity(WALLET))
    expect(older).not.toHaveBeenCalled()
    expect(result.current.hasMore).toBe(true)

    act(() => result.current.loadMore())
    await waitFor(() => expect(result.current.rows).toHaveLength(2))
    expect(older).toHaveBeenCalledWith({ chainId: 1, wallet: WALLET, before: undefined, rows: true })
    expect(older).toHaveBeenCalledWith({ chainId: 8453, wallet: WALLET, before: undefined, rows: true })
    // The event both sources hold is shown once; the older one has its token amount and no USD value.
    expect(result.current.rows[1]).toMatchObject({ id: "1:0xold:0", tokenAmountLabel: "7 USDC" })
    expect(result.current.rows[1]!.amountUsd).toBeUndefined()
    expect(result.current.isLoadingMore).toBe(false)
    expect(result.current.hasMore).toBe(true)

    older.mockClear()
    act(() => result.current.loadMore())
    await waitFor(() => expect(older).toHaveBeenCalledTimes(2))
    // The next page continues from the cursor; the rate-limited chain is asked again from its start.
    expect(older).toHaveBeenCalledWith({ chainId: 1, wallet: WALLET, before: "500", rows: true })
    expect(older).toHaveBeenCalledWith({ chainId: 8453, wallet: WALLET, before: undefined, rows: true })

    older.mockImplementation(async () => ({ status: "ok", next: null, rows: [] }))
    older.mockClear()
    await waitFor(() => expect(result.current.isLoadingMore).toBe(false))
    act(() => result.current.loadMore())
    await waitFor(() => expect(result.current.hasMore).toBe(false))
    expect(older).toHaveBeenCalledTimes(1)
    expect(older).toHaveBeenCalledWith({ chainId: 8453, wallet: WALLET, before: undefined, rows: true })
  })

  it("is empty for a guest", () => {
    const { result } = renderHook(() => useWalletActivity(null))
    expect(result.current).toMatchObject({ rows: [], hasMore: false, isLoadingMore: false })
  })
})
