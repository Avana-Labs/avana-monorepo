import crypto from "node:crypto"
import { cookies } from "next/headers"
import { assertSameOriginRead, clientKey, rateLimitShared } from "../../_lib/request-guards"

export const dynamic = "force-dynamic"

/** Issue a single-use SIWE nonce, bound to the client via an httpOnly cookie. */
export async function GET(request: Request) {
  // GET endpoint: browsers omit the Origin header on a same-origin GET, so the app's own nonce fetch
  // arrives with no Origin and the POST-tuned assertSameOrigin (fail-closed on a missing Origin) 403s
  // it. Use the GET-tuned guard (keyed off the unforgeable, browser-set Sec-Fetch-Site) like
  // /api/fx-rates. Cross-site is still blocked; the nonce is single-use + cookie-bound and useless
  // without a signed /verify, so a same-origin/navigation nonce is harmless.
  if (!assertSameOriginRead(request)) return Response.json({ error: "origin not allowed" }, { status: 403 })
  if (!(await rateLimitShared(`siwe-nonce:${clientKey(request)}`, 30, 60_000))) {
    return Response.json({ error: "too many nonce requests" }, { status: 429 })
  }

  const nonce = crypto.randomBytes(16).toString("hex")
  const jar = await cookies()
  jar.set("siwe-nonce", nonce, {
    httpOnly: true,
    sameSite: "lax",
    secure: process.env.NODE_ENV === "production",
    path: "/",
    maxAge: 600,
  })
  return Response.json({ nonce })
}
