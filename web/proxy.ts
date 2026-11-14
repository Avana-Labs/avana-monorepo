import { type NextRequest, NextResponse } from "next/server"
import { buildContentSecurityPolicy } from "@/lib/content-security-policy.mjs"

/**
 * Per-request CSP nonce. Setting the CSP (with the nonce) on the forwarded REQUEST headers lets
 * Next.js apply the same nonce to its own framework <script> tags automatically; the app's inline
 * scripts read the nonce from `x-nonce`. This replaces the blanket `script-src 'unsafe-inline'`
 * in production with a nonce + strict-dynamic policy.
 */
export function proxy(request: NextRequest) {
  const isDev = process.env.NODE_ENV === "development"
  const nonce = btoa(crypto.randomUUID())
  const csp = buildContentSecurityPolicy({ nonce, isDev })

  const requestHeaders = new Headers(request.headers)
  requestHeaders.set("x-nonce", nonce)
  requestHeaders.set("content-security-policy", csp)

  const response = NextResponse.next({ request: { headers: requestHeaders } })
  response.headers.set("content-security-policy", csp)
  return response
}

export const config = {
  matcher: [
    // Run on document requests; skip static assets and image optimization (they need no CSP and
    // stay cacheable). Also skip Next's prefetch requests.
    {
      // Skip Sentry tunnel (`/monitoring`) so client error reporting is not rewritten/CSP-blocked.
      source:
        "/((?!_next/static|_next/image|monitoring|favicon.ico|.*\\.(?:png|jpg|jpeg|gif|svg|ico|webp|txt|xml)$).*)",
      missing: [
        { type: "header", key: "next-router-prefetch" },
        { type: "header", key: "purpose", value: "prefetch" },
      ],
    },
  ],
}
