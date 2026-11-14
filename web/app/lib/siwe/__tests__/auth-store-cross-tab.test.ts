import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import {
  clearSiweToken,
  fetchSiweAccessToken,
  getSiweSession,
  getSiweToken,
  setSiweSession,
  subscribeSiwe,
} from "@/app/lib/siwe/auth-store"

const AUTH_EVENT_KEY = "avana.siwe.event.v2"
const LEGACY_STORAGE_KEY = "avana.siwe.token.v1"
const WALLET = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"

function liveJwt(label: string) {
  const payload = Buffer.from(JSON.stringify({ exp: Math.floor(Date.now() / 1000) + 900 })).toString("base64url")
  return `header.${payload}.${label}`
}

function tokenResponse(token: string) {
  return { ok: true, status: 200, json: async () => ({ token, wallet: WALLET }) } as Response
}

function fireAuthEvent(session: { wallet: string } | null) {
  window.dispatchEvent(
    new StorageEvent("storage", {
      key: AUTH_EVENT_KEY,
      newValue: JSON.stringify({ session, at: Date.now() }),
    }),
  )
}

describe("SIWE memory-only auth store", () => {
  beforeEach(() => {
    clearSiweToken()
    vi.restoreAllMocks()
  })
  afterEach(() => clearSiweToken())

  it("never persists the Convex bearer token", async () => {
    setSiweSession(WALLET)
    const token = liveJwt("live")
    vi.spyOn(globalThis, "fetch").mockResolvedValue(tokenResponse(token))

    await expect(fetchSiweAccessToken()).resolves.toBe(token)
    expect(getSiweToken()).toEqual({ jwt: token, wallet: WALLET })
    expect(window.sessionStorage.getItem(LEGACY_STORAGE_KEY)).toBeNull()
    expect(window.localStorage.getItem(LEGACY_STORAGE_KEY)).toBeNull()
    expect(document.cookie).not.toContain("live-jwt")
  })

  it("single-flights simultaneous access-token refreshes", async () => {
    setSiweSession(WALLET)
    const token = liveJwt("one")
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(tokenResponse(token))

    await expect(
      Promise.all([fetchSiweAccessToken(), fetchSiweAccessToken(), fetchSiweAccessToken()]),
    ).resolves.toEqual([token, token, token])
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it("applies a logout event from another tab", () => {
    setSiweSession(WALLET)
    const listener = vi.fn()
    const unsubscribe = subscribeSiwe(listener)

    fireAuthEvent(null)

    expect(getSiweSession()).toBeNull()
    expect(listener).toHaveBeenCalled()
    unsubscribe()
  })

  it("ignores storage events for unrelated keys", () => {
    setSiweSession(WALLET)
    window.dispatchEvent(new StorageEvent("storage", { key: "some-other-key", newValue: "x" }))
    expect(getSiweSession()).toEqual({ wallet: WALLET })
  })

  it("force-refreshes via /api/siwe/token when open-gate is off", async () => {
    setSiweSession(WALLET)
    const token = liveJwt("cookie")
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(tokenResponse(token))

    await expect(fetchSiweAccessToken(true)).resolves.toBe(token)
    expect(fetchMock).toHaveBeenCalledWith("/api/siwe/token", expect.objectContaining({ method: "POST" }))
  })

  // Convex awaits this token with its socket paused and has no catch: a rejection used to leave
  // every signed-in query hanging until reload.
  it("a network failure during refresh resolves to the still-valid token instead of rejecting", async () => {
    setSiweSession(WALLET)
    const token = liveJwt("cached")
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(tokenResponse(token))
    await fetchSiweAccessToken()

    fetchMock.mockRejectedValue(new TypeError("Failed to fetch"))
    await expect(fetchSiweAccessToken(true)).resolves.toBe(token)
    expect(getSiweSession()).toEqual({ wallet: WALLET })
  })

  it("a server error with no cached token resolves to null and keeps the session", async () => {
    setSiweSession(WALLET)
    vi.spyOn(globalThis, "fetch").mockResolvedValue({ ok: false, status: 503, json: async () => ({}) } as Response)

    await expect(fetchSiweAccessToken(true)).resolves.toBeNull()
    expect(getSiweSession()).toEqual({ wallet: WALLET })
  })

  it("open-gate force-refresh uses /api/siwe/dev-token and keeps the session on cookie 401s", async () => {
    vi.resetModules()
    vi.doMock("@/app/lib/test-mode", () => ({
      shouldUseOpenGateSession: () => true,
    }))
    const store = await import("@/app/lib/siwe/auth-store")
    store.clearSiweToken()
    store.setSiweToken(liveJwt("open"), WALLET)

    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(tokenResponse(liveJwt("refreshed")))
    await expect(store.fetchSiweAccessToken(true)).resolves.toMatch(/refreshed/)
    expect(fetchMock).toHaveBeenCalledWith("/api/siwe/dev-token", expect.objectContaining({ method: "POST" }))
    expect(store.getSiweSession()).toEqual({ wallet: WALLET })

    fetchMock.mockResolvedValue({ ok: false, status: 401, json: async () => ({}) } as Response)
    await expect(store.fetchSiweAccessToken(true)).resolves.toBeNull()
    expect(store.getSiweSession()).toEqual({ wallet: WALLET })

    store.clearSiweToken()
    vi.doUnmock("@/app/lib/test-mode")
    vi.resetModules()
  })
})
