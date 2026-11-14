import { cleanup, renderHook, waitFor } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { clearSiweToken, getSiweToken } from "@/app/lib/siwe/auth-store"

const { WALLET } = vi.hoisted(() => ({ WALLET: "0x70997970c51812dc3a010c7d01b50e0d17dc79c8" }))

vi.mock("@/app/lib/test-mode", () => ({
  shouldUseOpenGateSession: () => true,
  TEST_MODE_WALLET_ADDRESS: WALLET,
}))

import { useOpenGateAuthBootstrap } from "../use-open-gate-auth-bootstrap"

function tokenResponse() {
  const payload = Buffer.from(JSON.stringify({ exp: Math.floor(Date.now() / 1000) + 900 })).toString("base64url")
  return {
    ok: true,
    status: 200,
    json: async () => ({ token: `header.${payload}.signature`, wallet: WALLET }),
  } as Response
}

describe("useOpenGateAuthBootstrap", () => {
  beforeEach(() => {
    clearSiweToken()
    vi.restoreAllMocks()
  })

  afterEach(() => {
    cleanup()
    clearSiweToken()
  })

  it("single-flights token minting across concurrent provider mounts", async () => {
    let resolveFetch!: (response: Response) => void
    const fetchMock = vi.spyOn(globalThis, "fetch").mockReturnValue(
      new Promise((resolve) => {
        resolveFetch = resolve
      }),
    )

    const first = renderHook(() => useOpenGateAuthBootstrap())
    const second = renderHook(() => useOpenGateAuthBootstrap())

    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1))
    resolveFetch(tokenResponse())

    await waitFor(() => {
      expect(first.result.current.ready).toBe(true)
      expect(second.result.current.ready).toBe(true)
    })
    expect(getSiweToken()?.wallet).toBe(WALLET)
  })
})
