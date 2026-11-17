import { NextResponse } from "next/server"
import { assertSameOriginRead } from "../_lib/request-guards"
import { buildSearchIndex } from "@/app/lib/search/search-index-server"

const MAX_AGE_SECONDS = 30

/** The header search's pools, borrowable assets and Lend markets (`search-index-server.ts`). Same-origin reads only. */
export async function GET(request: Request) {
  if (!assertSameOriginRead(request)) {
    return NextResponse.json({ error: "origin not allowed" }, { status: 403 })
  }
  const index = await buildSearchIndex()
  return NextResponse.json(index, {
    headers: { "Cache-Control": `private, max-age=${MAX_AGE_SECONDS}` },
  })
}
