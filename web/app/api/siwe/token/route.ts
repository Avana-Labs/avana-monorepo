import { cookies } from "next/headers"
import { mintConvexJwt, resolveIssuer, verifySiweSessionJwt } from "@/app/lib/siwe/jwt"
import { assertSameOrigin } from "../../_lib/request-guards"

export const dynamic = "force-dynamic"

export async function POST(req: Request) {
  if (!assertSameOrigin(req)) return Response.json({ error: "origin not allowed" }, { status: 403 })

  const session = (await cookies()).get("avana_siwe")?.value
  const verified = session ? verifySiweSessionJwt(session) : null
  if (!verified) {
    return Response.json({ error: "session expired" }, { status: 401, headers: { "cache-control": "no-store" } })
  }

  const token = mintConvexJwt(verified.wallet, resolveIssuer(new URL(req.url).origin))
  return Response.json({ token, wallet: verified.wallet }, { headers: { "cache-control": "no-store" } })
}
