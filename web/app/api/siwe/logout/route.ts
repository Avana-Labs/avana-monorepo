import { cookies } from "next/headers"
import { assertSameOrigin } from "../../_lib/request-guards"

export const dynamic = "force-dynamic"

export async function POST(req: Request) {
  if (!assertSameOrigin(req)) return Response.json({ error: "origin not allowed" }, { status: 403 })

  const jar = await cookies()
  jar.set("avana_siwe", "", {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    maxAge: 0,
  })
  return new Response(null, { status: 204, headers: { "cache-control": "no-store" } })
}
