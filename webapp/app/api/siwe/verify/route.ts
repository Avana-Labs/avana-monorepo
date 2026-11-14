import { cookies } from "next/headers"
import type { Address, Hex } from "viem"
import {
  extractSiweAddress,
  extractSiweChainId,
  extractSiweDomain,
  extractSiweNonce,
  extractSiweUri,
} from "@/app/lib/siwe/message"
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

  const address = extractSiweAddress(message)
  const nonce = extractSiweNonce(message)
  if (!address || !nonce) {
    return Response.json({ error: "malformed SIWE message" }, { status: 400 })
  }

  // Bind the signature to THIS origin. EIP-4361 puts the domain/URI in the signed
  // payload precisely so a signature phished for another site cannot be relayed here.
  // The client signs with domain = window.location.host, so it must equal our host.
  const host = req.headers.get("host")
  const domain = extractSiweDomain(message)
  if (!domain || (host && domain !== host)) {
    return Response.json({ error: "SIWE domain does not match this origin" }, { status: 401 })
  }
  const uri = extractSiweUri(message)
  if (uri) {
    try {
      const uriHost = new URL(uri).host
      if (host && uriHost !== host) {
        return Response.json({ error: "SIWE URI does not match this origin" }, { status: 401 })
      }
    } catch {
      return Response.json({ error: "malformed SIWE URI" }, { status: 400 })
    }
  }

  // Bind to the app's target network (mainnet-only wagmi config). Defense-in-depth: a message
  // signed for a different chain is not accepted here.
  if (extractSiweChainId(message) !== TARGET_CHAIN_ID) {
    return Response.json({ error: "SIWE chain does not match this app" }, { status: 401 })
  }

  const jar = await cookies()
  const expectedNonce = jar.get("siwe-nonce")?.value
  if (!expectedNonce || expectedNonce !== nonce) {
    return Response.json({ error: "invalid or expired nonce" }, { status: 401 })
  }

  const signatureIsValid = await verifySiweSignature({
    address: address as Address,
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
