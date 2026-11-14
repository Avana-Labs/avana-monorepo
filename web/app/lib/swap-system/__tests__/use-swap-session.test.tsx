import { renderHook, waitFor } from "@testing-library/react"
import { act } from "react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { useSwapSession } from "@/app/lib/swap-system"

describe("useSwapSession", () => {
  beforeEach(() => localStorage.clear())

  it("executes a native wallet swap through shared session state", async () => {
    const { result } = renderHook(() => useSwapSession({ walletId: "demo-wallet", persistState: false }))
    const quote = await result.current.getQuote({
      chainId: 1,
      inputAssetId: "eth",
      outputAssetId: "usdc",
      inputAmount: 0.001,
      slippageBps: 50,
    })

    await act(async () => {
      await result.current.executeSwap(quote)
    })

    await waitFor(() => {
      expect(result.current.transactionHistory[0]).toMatchObject({ status: "confirmed" })
    })
    expect(result.current.walletBalances.find((balance) => balance.id === "wallet-eth")?.amount).toBe(0.011)
  })

  it("sees approved ERC-20 allowance immediately for the following executeSwap", async () => {
    const { result } = renderHook(() => useSwapSession({ walletId: "demo-wallet", persistState: false }))
    const quote = await result.current.getQuote({
      chainId: 1,
      inputAssetId: "usdc",
      outputAssetId: "eth",
      inputAmount: 100,
      slippageBps: 50,
    })

    expect(result.current.requiresApproval("usdc", 100)).toBe(true)

    await act(async () => {
      const approval = await result.current.approve("usdc", 100)
      expect(approval.status).toBe("approval_confirmed")
      // Must succeed in the same turn — before React re-renders from setState.
      const swap = await result.current.executeSwap(quote)
      expect(swap.status).toBe("confirmed")
    })

    await waitFor(() => {
      expect(result.current.transactionHistory[0]).toMatchObject({ status: "confirmed" })
    })
    expect(result.current.requiresApproval("usdc", 100)).toBe(false)
  })

  it("returns an immediate indicative quote while the server quote is pending", async () => {
    const serverGetQuote = vi.fn(() => new Promise<never>(() => undefined))
    const { result } = renderHook(() =>
      useSwapSession({ walletId: "demo-wallet", persistState: false, serverGetQuote }),
    )
    const request = {
      chainId: 1,
      inputAssetId: "eth",
      outputAssetId: "usdc",
      inputAmount: 0.001,
      slippageBps: 50,
    }

    const indicativeQuote = await result.current.getIndicativeQuote(request)

    expect(indicativeQuote).toMatchObject({
      status: "valid",
      inputAmount: request.inputAmount,
      inputAssetId: request.inputAssetId,
      outputAssetId: request.outputAssetId,
    })
    expect(indicativeQuote.estimatedOutputAmount).toBeGreaterThan(0)
    expect(serverGetQuote).not.toHaveBeenCalled()
  })

  it("rehydrates wallet balances and transaction history", async () => {
    const walletId = "persisted-swap-wallet"
    const first = renderHook(() => useSwapSession({ walletId }))
    await waitFor(() => expect(first.result.current.isHydrated).toBe(true))
    const quote = await first.result.current.getQuote({
      chainId: 1,
      inputAssetId: "eth",
      outputAssetId: "usdc",
      inputAmount: 0.001,
      slippageBps: 50,
    })

    await act(async () => {
      await first.result.current.executeSwap(quote)
    })
    await waitFor(() => expect(first.result.current.transactionHistory).toHaveLength(1))
    first.unmount()

    const restored = renderHook(() => useSwapSession({ walletId }))
    await waitFor(() => expect(restored.result.current.isHydrated).toBe(true))
    expect(restored.result.current.transactionHistory[0]).toMatchObject({
      inputAssetId: "eth",
      outputAssetId: "usdc",
      status: "confirmed",
    })
    expect(restored.result.current.walletBalances.find((balance) => balance.assetId === "eth")?.amount).toBe(0.011)
  })
})
