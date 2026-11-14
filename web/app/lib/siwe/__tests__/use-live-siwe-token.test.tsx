import { renderHook } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { useConvexSiweAuth, useLiveSiweToken } from "@/app/lib/siwe/use-siwe-auth"
import { clearSiweToken, setSiweSession } from "@/app/lib/siwe/auth-store"

const WALLET = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"

function liveJwt() {
  const payload = Buffer.from(JSON.stringify({ exp: Math.floor(Date.now() / 1000) + 900 })).toString("base64url")
  return `header.${payload}.signature`
}

describe("memory-only Convex authentication", () => {
  beforeEach(() => {
    clearSiweToken()
    vi.restoreAllMocks()
  })
  afterEach(() => clearSiweToken())

  it("exposes only wallet session metadata", () => {
    setSiweSession(WALLET)
    const { result } = renderHook(() => useLiveSiweToken())
    expect(result.current).toEqual({ wallet: WALLET })
    expect(result.current).not.toHaveProperty("jwt")
  })

  it("reports unauthenticated to Convex without a session", async () => {
    const { result } = renderHook(() => useConvexSiweAuth())
    expect(result.current.isAuthenticated).toBe(false)
    await expect(result.current.fetchAccessToken({ forceRefreshToken: false })).resolves.toBeNull()
  })

  it("fetches a bearer token on demand for an authenticated session", async () => {
    setSiweSession(WALLET)
    const token = liveJwt()
    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ token, wallet: WALLET }),
    } as Response)
    const { result } = renderHook(() => useConvexSiweAuth())

    expect(result.current.isAuthenticated).toBe(true)
    await expect(result.current.fetchAccessToken({ forceRefreshToken: false })).resolves.toBe(token)
  })
})
