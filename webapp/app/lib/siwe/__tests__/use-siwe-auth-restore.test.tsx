import { renderHook } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it } from "vitest"
import { useSiweAuth } from "@/app/lib/siwe/use-siwe-auth"
import { clearSiweToken, setSiweSession } from "@/app/lib/siwe/auth-store"

const WALLET = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"

describe("useSiweAuth", () => {
  beforeEach(() => clearSiweToken())
  afterEach(() => clearSiweToken())

  it("reports signed-out without a server-owned session", () => {
    const { result } = renderHook(() => useSiweAuth())
    expect(result.current.isSignedIn).toBe(false)
    expect(result.current.authedWallet).toBe(null)
  })

  it("reports signed-in from non-secret session metadata", () => {
    setSiweSession(WALLET)
    const { result } = renderHook(() => useSiweAuth())
    expect(result.current.isSignedIn).toBe(true)
    expect(result.current.authedWallet).toBe(WALLET)
  })
})
