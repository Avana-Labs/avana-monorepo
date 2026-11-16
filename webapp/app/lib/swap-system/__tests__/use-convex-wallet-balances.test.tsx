import { renderHook } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

const { useQuery, rpc } = vi.hoisted(() => ({ useQuery: vi.fn(() => undefined), rpc: { set: true } }))
vi.mock("convex/react", () => ({ useQuery }))
vi.mock("@/app/lib/convex/has-convex-client", () => ({ hasConvexClient: true }))
vi.mock("@/app/lib/chain/public-client", () => ({
  chainPublicClient: () => (rpc.set ? { watchBlockNumber: () => () => {} } : null),
}))

import { useConvexProductWalletBalances } from "@/app/lib/swap-system/use-convex-wallet-balances"
import { chainIds } from "@/app/lib/chains"
import { setActiveChainKey } from "@/app/lib/web3/active-chain"

afterEach(() => {
  useQuery.mockClear()
  setActiveChainKey("ethereum")
  rpc.set = true
})

const args = () => (useQuery.mock.calls as unknown as Array<[unknown, unknown]>).map((call) => call[1])

describe("wallet balance reads", () => {
  it("reads nothing for a guest id", () => {
    const { result } = renderHook(() => useConvexProductWalletBalances("guest-1"))
    expect(result.current).toEqual([])
    expect(args().every((a) => a === "skip")).toBe(true)
  })

  it("loads the active chain's tokens and markets for a wallet address", () => {
    setActiveChainKey("base")
    const { result } = renderHook(() => useConvexProductWalletBalances("0x00000000000000000000000000000000000000aa"))
    expect(result.current).toBeUndefined()
    expect(args()).toContainEqual({ chainId: chainIds().base })
    expect(args()).not.toContainEqual({ chainId: chainIds().ethereum })
  })

  it("answers empty on a chain without an RPC", () => {
    rpc.set = false
    const { result } = renderHook(() => useConvexProductWalletBalances("0x00000000000000000000000000000000000000aa"))
    expect(result.current).toEqual([])
  })
})
