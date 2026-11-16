import { cookies } from "next/headers"
import { verifySiweSessionJwt } from "@/app/lib/siwe/jwt"
import { assertSameOrigin, assertSameOriginRead } from "../../_lib/request-guards"

export const dynamic = "force-dynamic"

/**
 * Test funds for the signed-in wallet, from the local faucet (services/faucet). The faucet listens on 127.0.0.1 only,
 * so the app asks it from the server, for the wallet of the session cookie, never for an address the browser names.
 * FAUCET_URL (server-only) is set on the local network; elsewhere the route answers 404.
 *
 *   POST { "chain": "ethereum" | "base" }   grants once per wallet and chain; a repeat returns the recorded grant
 *   GET  ?chain=ethereum|base               the recorded grant, or 404
 */

const CHAINS = new Set(["ethereum", "base"])
const NO_STORE = { "cache-control": "no-store" }

function faucetUrl(): string | null {
  return process.env.FAUCET_URL?.trim().replace(/\/+$/, "") || null
}

async function sessionWallet(): Promise<string | null> {
  const session = (await cookies()).get("avana_siwe")?.value
  return (session ? verifySiweSessionJwt(session) : null)?.wallet ?? null
}

async function relay(response: Response): Promise<Response> {
  const body = await response.text()
  return new Response(body, { status: response.status, headers: { "content-type": "application/json", ...NO_STORE } })
}

export async function POST(req: Request) {
  if (!assertSameOrigin(req)) return Response.json({ error: "origin not allowed" }, { status: 403 })
  const base = faucetUrl()
  if (!base) return Response.json({ error: "no faucet on this network" }, { status: 404, headers: NO_STORE })
  const wallet = await sessionWallet()
  if (!wallet) return Response.json({ error: "sign in first" }, { status: 401, headers: NO_STORE })
  const { chain } = ((await req.json().catch(() => ({}))) ?? {}) as { chain?: unknown }
  if (typeof chain !== "string" || !CHAINS.has(chain)) return Response.json({ error: "unknown chain" }, { status: 400, headers: NO_STORE })
  try {
    return await relay(
      await fetch(`${base}/v1/grant`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ chain, wallet }) }),
    )
  } catch {
    return Response.json({ error: "the faucet is not running" }, { status: 502, headers: NO_STORE })
  }
}

export async function GET(req: Request) {
  if (!assertSameOriginRead(req)) return Response.json({ error: "origin not allowed" }, { status: 403 })
  const base = faucetUrl()
  if (!base) return Response.json({ error: "no faucet on this network" }, { status: 404, headers: NO_STORE })
  const wallet = await sessionWallet()
  if (!wallet) return Response.json({ error: "sign in first" }, { status: 401, headers: NO_STORE })
  const chain = new URL(req.url).searchParams.get("chain") ?? ""
  if (!CHAINS.has(chain)) return Response.json({ error: "unknown chain" }, { status: 400, headers: NO_STORE })
  try {
    return await relay(await fetch(`${base}/v1/grant?${new URLSearchParams({ chain, wallet })}`))
  } catch {
    return Response.json({ error: "the faucet is not running" }, { status: 502, headers: NO_STORE })
  }
}
