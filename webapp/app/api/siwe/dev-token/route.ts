import { mintConvexJwt, resolveIssuer } from "@/app/lib/siwe/jwt"
import { shouldUseOpenGateSession, TEST_MODE_WALLET_ADDRESS } from "@/app/lib/test-mode"
import { assertSameOrigin, clientKey, rateLimitShared } from "../../_lib/request-guards"

export const dynamic = "force-dynamic"

// A full product sweep remounts the Convex provider across many routes. Keep the
// development-only open-gate refresh budget high enough for that workflow while
// retaining a bounded per-client limit.
const OPEN_GATE_TOKEN_LIMIT_PER_MINUTE = 120

function isLoopbackIssuer(issuer: string) {
  try {
    const host = new URL(issuer).hostname
    return host === "localhost" || host === "127.0.0.1" || host === "::1"
  } catch {
    return false
  }
}

/**
 * Dev/open-gate only: mint a Convex JWT for TEST_MODE_WALLET_ADDRESS so Convex
 * wallet queries/mutations authenticate without a real SIWE signature.
 *
 * Hard-refuses in production builds (shouldUseOpenGateSession is structurally false
 * there). Same issuer/JWKS path as /api/siwe/verify — no auth fork.
 *
 * When the request origin is loopback but the app talks to cloud Convex, mint with
 * NEXT_PUBLIC_SIWE_ISSUER (public JWKS origin) so Convex can fetch keys. Loopback
 * issuers are unreachable from Convex cloud and leave open-gate stuck authenticating.
 */
export async function POST(req: Request) {
  if (!shouldUseOpenGateSession()) {
    return Response.json({ error: "dev token unavailable" }, { status: 404 })
  }
  if (!assertSameOrigin(req)) return Response.json({ error: "origin not allowed" }, { status: 403 })
  if (!(await rateLimitShared(`siwe-dev-token:${clientKey(req)}`, OPEN_GATE_TOKEN_LIMIT_PER_MINUTE, 60_000))) {
    return Response.json({ error: "too many requests" }, { status: 429 })
  }

  const requestOrigin = new URL(req.url).origin
  let issuer = resolveIssuer(requestOrigin)
  if (isLoopbackIssuer(issuer)) {
    const configured = process.env.NEXT_PUBLIC_SIWE_ISSUER?.trim().replace(/\/+$/, "")
    if (!configured || isLoopbackIssuer(configured)) {
      return Response.json(
        {
          error:
            "Set NEXT_PUBLIC_SIWE_ISSUER to a public origin Convex can reach (must match SIWE_JWT_ISSUER and serve /.well-known/jwks.json).",
        },
        { status: 503 },
      )
    }
    issuer = configured
  }

  const wallet = TEST_MODE_WALLET_ADDRESS.toLowerCase()
  const token = mintConvexJwt(wallet, issuer)
  return Response.json({ token, wallet, issuer })
}
