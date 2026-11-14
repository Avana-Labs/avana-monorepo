import { mintSiweSessionJwt, resolveIssuer, verifyConvexJwt, verifySiweSessionJwt } from "@/app/lib/siwe/jwt"
import { allowsLocalE2E, isIsolatedE2EStaging } from "@/app/lib/siwe/e2e-policy"
import { cookies } from "next/headers"
import { assertSameOrigin, clientKey, rateLimitShared } from "../../_lib/request-guards"

export const dynamic = "force-dynamic"

/**
 * E2E-only: mint the HttpOnly `avana_siwe` session cookie without a real SIWE signature.
 *
 * Allowed when:
 * - Playwright test mode is on (local suite), OR
 * - `x-avana-e2e-secret` matches `AVANA_E2E_SESSION_SECRET` (staging action lifecycles).
 *
 * Accepts either `{ wallet }` or `{ token }` (Convex/session JWT used only to extract wallet).
 * Never returns a Convex access JWT in the body — clients must call `/api/siwe/token`.
 */
export async function POST(req: Request) {
  const secret = process.env.AVANA_E2E_SESSION_SECRET?.trim()
  const provided = req.headers.get("x-avana-e2e-secret")?.trim()
  const secretOk = Boolean(isIsolatedE2EStaging() && secret && provided && secret === provided)
  if (!allowsLocalE2E() && !secretOk) {
    return Response.json({ error: "e2e session unavailable" }, { status: 404 })
  }
  // Fail closed without Origin unless an e2e secret authorized the mint (Playwright API
  // requests always send Origin from the helper; secret-only staging calls may be server-side).
  if (!assertSameOrigin(req) && !secretOk) {
    return Response.json({ error: "origin not allowed" }, { status: 403 })
  }
  if (!(await rateLimitShared(`siwe-e2e-session:${clientKey(req)}`, 60, 60_000))) {
    return Response.json({ error: "too many requests" }, { status: 429 })
  }

  let body: { wallet?: string; token?: string }
  try {
    body = (await req.json()) as { wallet?: string; token?: string }
  } catch {
    return Response.json({ error: "invalid json" }, { status: 400 })
  }

  let wallet = typeof body.wallet === "string" ? body.wallet.toLowerCase() : ""
  if (!wallet && typeof body.token === "string") {
    const verified = verifySiweSessionJwt(body.token) ?? verifyConvexJwt(body.token)
    wallet = verified?.wallet ?? ""
  }
  if (!/^0x[0-9a-f]{40}$/.test(wallet)) {
    return Response.json({ error: "wallet required" }, { status: 400 })
  }

  const issuer = resolveIssuer(new URL(req.url).origin)
  const session = mintSiweSessionJwt(wallet, issuer)
  const jar = await cookies()
  jar.set("avana_siwe", session, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    maxAge: 7 * 24 * 60 * 60,
  })
  return Response.json({ wallet }, { headers: { "cache-control": "no-store" } })
}
