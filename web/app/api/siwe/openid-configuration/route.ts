import { resolveIssuer } from "@/app/lib/siwe/jwt"

export const dynamic = "force-dynamic"

/**
 * OIDC discovery doc. Convex fetches `${domain}/.well-known/openid-configuration`
 * (rewritten here) to discover the JWKS and verify the app's JWTs.
 */
export async function GET(req: Request) {
  const origin = new URL(req.url).origin
  const issuer = resolveIssuer(origin)
  return Response.json({
    issuer,
    jwks_uri: `${origin}/.well-known/jwks.json`,
    response_types_supported: ["id_token"],
    subject_types_supported: ["public"],
    id_token_signing_alg_values_supported: ["RS256"],
  })
}
