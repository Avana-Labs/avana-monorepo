import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

const WALLET = "0x00000000000000000000000000000000000A11cE"
let session: string | undefined = "session-jwt"

vi.mock("next/headers", () => ({ cookies: async () => ({ get: () => (session ? { value: session } : undefined) }) }))
vi.mock("@/app/lib/siwe/jwt", () => ({ verifySiweSessionJwt: (t: string) => (t === "session-jwt" ? { wallet: WALLET, exp: 0 } : null) }))
vi.mock("../../_lib/request-guards", () => ({ assertSameOrigin: () => true, assertSameOriginRead: () => true }))

const { GET, POST } = await import("../grant/route")

const post = (body: unknown) => new Request("http://localhost:3000/api/faucet/grant", { method: "POST", body: JSON.stringify(body) })

describe("faucet grant route", () => {
  const fetchMock = vi.fn(async () => new Response(JSON.stringify({ chain: "ethereum", wallet: WALLET, steps: [] }), { status: 201 }))

  beforeEach(() => {
    session = "session-jwt"
    vi.stubEnv("FAUCET_URL", "http://127.0.0.1:42080/")
    vi.stubGlobal("fetch", fetchMock)
    fetchMock.mockClear()
  })
  afterEach(() => {
    vi.unstubAllEnvs()
    vi.unstubAllGlobals()
  })

  it("asks the faucet for the session's wallet, never one the browser names", async () => {
    const res = await POST(post({ chain: "ethereum", wallet: "0x0000000000000000000000000000000000000bad" }))
    expect(res.status).toBe(201)
    expect(fetchMock).toHaveBeenCalledWith("http://127.0.0.1:42080/v1/grant", expect.objectContaining({ method: "POST", body: JSON.stringify({ chain: "ethereum", wallet: WALLET }) }))
  })

  it("reads the recorded grant", async () => {
    await GET(new Request("http://localhost:3000/api/faucet/grant?chain=base"))
    expect(fetchMock).toHaveBeenCalledWith(`http://127.0.0.1:42080/v1/grant?chain=base&wallet=${WALLET}`)
  })

  it("refuses without a session, an unknown chain, or a network with no faucet", async () => {
    expect((await POST(post({ chain: "polygon" }))).status).toBe(400)
    session = undefined
    expect((await POST(post({ chain: "ethereum" }))).status).toBe(401)
    vi.stubEnv("FAUCET_URL", "")
    expect((await POST(post({ chain: "ethereum" }))).status).toBe(404)
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it("answers 502 when the faucet is not running", async () => {
    fetchMock.mockRejectedValueOnce(new Error("ECONNREFUSED"))
    expect((await POST(post({ chain: "base" }))).status).toBe(502)
  })
})
