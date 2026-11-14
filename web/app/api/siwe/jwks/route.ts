import { getPublicJwk } from "@/app/lib/siwe/jwt"

export const dynamic = "force-dynamic"

/** JWKS for the app's Convex JWT issuer. Served at /.well-known/jwks.json via a rewrite. */
export async function GET() {
  return Response.json({ keys: [getPublicJwk()] }, { headers: { "cache-control": "no-store" } })
}
