import crypto from "node:crypto"
import { mintAskGuestJwt, resolveIssuer } from "@/app/lib/siwe/jwt"
import { ASK_AI_GUEST_COOKIE, guestMintDecision, readAskGuestId, readClientIp, signGuestId } from "./route-utils"

export const runtime = "nodejs"

export async function POST(request: Request) {
  const existingGuestId = readAskGuestId(request.headers.get("cookie"))
  const decision = existingGuestId ? "allowed" : await guestMintDecision(readClientIp(request))
  if (decision === "unavailable") {
    console.error("[ask-ai] guest sessions unavailable: shared mint limiter misconfigured or unreachable")
    return Response.json(
      { error: "Ask AI is temporarily unavailable. Try again in a moment." },
      { status: 503, headers: { "Cache-Control": "no-store, private", "Retry-After": "30" } },
    )
  }
  if (decision === "limited") {
    return Response.json(
      { error: "Too many new Ask AI sessions from this network. Try again later." },
      {
        status: 429,
        headers: {
          "Cache-Control": "no-store, private",
          "Retry-After": String(60 * 60),
        },
      },
    )
  }
  const guestId = existingGuestId ?? crypto.randomUUID()
  const token = mintAskGuestJwt(guestId, resolveIssuer(new URL(request.url).origin))
  const response = Response.json(
    { jwt: token, subject: `ask-guest:${guestId}` },
    { headers: { "Cache-Control": "no-store, private" } },
  )
  if (!existingGuestId) {
    response.headers.append(
      "Set-Cookie",
      `${ASK_AI_GUEST_COOKIE}=${signGuestId(guestId)}; Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax${
        process.env.NODE_ENV === "production" ? "; Secure" : ""
      }`,
    )
  }
  return response
}
