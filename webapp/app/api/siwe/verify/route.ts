import { cookies } from "next/headers"
import type { Hex } from "viem"
import { checkSiweMessage } from "@/app/lib/siwe/verify-message"
import { mintSiweSessionJwt, resolveIssuer } from "@/app/lib/siwe/jwt"
import { verifySiweSignature } from "@/app/lib/siwe/signature"
import { TARGET_CHAIN_ID } from "@/app/lib/web3/target-chain"
import { assertSameOrigin, clientKey, rateLimitShared } from "../../_lib/request-guards"

export const dynamic = "force-dynamic"

/**
 * Verify a SIWE signature and establish a server-owned browser session. The
 * session JWT has a distinct audience/scope and is never accepted by Convex.
 */
export async function POST(req: Request) {
  if (!assertSameOrigin(req)) return Response.json({ error: "origin not allowed" }, { status: 403 })
  if (!(await rateLimitShared(`siwe-verify:${clientKey(req)}`, 20, 60_000))) {
    return Response.json({ error: "too many verification attempts" }, { status: 429 })
  }

  let body: { message?: unknown; signature?: unknown }
  try {
    body = await req.json()
  } catch {
    return Response.json({ error: "invalid body" }, { status: 400 })
  }
  const { message, signature } = body
  if (typeof message !== "string" || typeof signature !== "string") {
    return Response.json({ error: "message and signature are required" }, { status: 400 })
  }

  // Bind the signature to THIS origin, the nonce issued to this browser, the app's chain and
  // the message's time window. EIP-4361 puts the domain/URI in the signed payload so a
  // signature phished for another site cannot be relayed here; the client signs with
  // domain = window.location.host.
  const host = req.headers.get("host")
  const jar = await cookies()
  const expectedNonce = jar.get("siwe-nonce")?.value
  if (!host) return Response.json({ error: "missing host" }, { status: 400 })
  if (!expectedNonce) return Response.json({ error: "invalid or expired nonce" }, { status: 401 })
  const checked = checkSiweMessage(message, { host, nonce: expectedNonce, chainId: TARGET_CHAIN_ID })
  if (!checked.ok) return Response.json({ error: checked.error }, { status: checked.status })
  const { address } = checked

  const signatureIsValid = await verifySiweSignature({
    address,
    message,
    signature: signature as Hex,
  })
  if (!signatureIsValid) {
    return Response.json({ error: "signature does not match address" }, { status: 401 })
  }

  // Single-use: burn the nonce so the signed message can't be replayed.
  jar.delete("siwe-nonce")

  const issuer = resolveIssuer(new URL(req.url).origin)
  const session = mintSiweSessionJwt(address, issuer)
  jar.set("avana_siwe", session, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    maxAge: 7 * 24 * 60 * 60,
  })
  return Response.json({ wallet: address.toLowerCase() }, { headers: { "cache-control": "no-store" } })
}
