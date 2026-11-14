import { renderHook, act } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

// Keep test mode off so detection is exercised (test mode disables it by design).
vi.mock("@/app/lib/test-mode", () => ({
  IS_DEV_SHORTCUT_MODE: false,
  IS_OPEN_GATE_TEST_MODE: false,
  TEST_MODE_WALLET_ADDRESS: "0x0000000000000000000000000000000000000a11",
}))

const account = { isConnected: false as boolean, chainId: undefined as number | undefined }
const switchChainAsync = vi.fn<(args: { chainId: number }) => Promise<unknown>>()
let isPending = false

vi.mock("wagmi", () => ({
  useAccount: () => account,
  useSwitchChain: () => ({ switchChainAsync, isPending }),
}))

import { useWrongNetwork } from "../use-wrong-network"

describe("useWrongNetwork", () => {
  beforeEach(() => {
    account.isConnected = false
    account.chainId = undefined
    isPending = false
    switchChainAsync.mockReset()
  })
  afterEach(() => vi.clearAllMocks())

  it("is not wrong when disconnected", () => {
    const { result } = renderHook(() => useWrongNetwork())
    expect(result.current.isWrongNetwork).toBe(false)
  })

  it("is not wrong when connected to the target chain (mainnet)", () => {
    account.isConnected = true
    account.chainId = 1
    const { result } = renderHook(() => useWrongNetwork())
    expect(result.current.isWrongNetwork).toBe(false)
  })

  it("flags a wrong network when connected to a non-target chain", () => {
    account.isConnected = true
    account.chainId = 137 // Polygon
    const { result } = renderHook(() => useWrongNetwork())
    expect(result.current.isWrongNetwork).toBe(true)
    expect(result.current.targetChainId).toBe(1)
    expect(result.current.targetChainName).toBe("Ethereum")
  })

  it("switches to the target chain and reports success", async () => {
    account.isConnected = true
    account.chainId = 137
    switchChainAsync.mockResolvedValueOnce({})
    const { result } = renderHook(() => useWrongNetwork())

    let ok: boolean | undefined
    await act(async () => {
      ok = await result.current.switchToTargetChain()
    })

    expect(switchChainAsync).toHaveBeenCalledWith({ chainId: 1 })
    expect(ok).toBe(true)
    expect(result.current.switchError).toBeNull()
  })

  it("handles a rejected switch gracefully without throwing", async () => {
    account.isConnected = true
    account.chainId = 137
    switchChainAsync.mockRejectedValueOnce(new Error("User rejected the request."))
    const { result } = renderHook(() => useWrongNetwork())

    let ok: boolean | undefined
    await act(async () => {
      ok = await result.current.switchToTargetChain()
    })

    expect(ok).toBe(false)
    expect(result.current.switchError).toBe("User rejected the request.")
  })
})
