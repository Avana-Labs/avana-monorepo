/* global process, URL */
// No `node:` imports: this module is bundled into the Edge middleware runtime, whose dev
// (turbopack) runtime rejects native modules like `node:process`. `process.env` and `URL` are
// available as globals in both the Edge and Node runtimes, so we use them directly.

/**
 * Shared Content-Security-Policy builder. Used by the request middleware (which injects a
 * per-request nonce and drops `script-src 'unsafe-inline'` in production) so the app's inline
 * scripts run under a nonce instead of the blanket inline allowance.
 *
 * Convex's reactive client connects over a WebSocket (https→wss, http→ws) and also falls back to
 * HTTP `/api/query`; connect-src MUST allow that backend origin in BOTH transports or every
 * client-side useQuery/useMutation is silently blocked. Origins are derived from the public Convex
 * env so dev (http/ws on 127.0.0.1) and prod (https/wss on *.convex.cloud) both work.
 */
function convexConnectOrigins() {
  const origins = new Set()
  for (const raw of [process.env.NEXT_PUBLIC_CONVEX_URL, process.env.NEXT_PUBLIC_CONVEX_SITE_URL]) {
    if (!raw) continue
    try {
      const u = new URL(raw)
      const wsProto = u.protocol === "https:" ? "wss:" : "ws:"
      origins.add(`${u.protocol}//${u.host}`)
      origins.add(`${wsProto}//${u.host}`)
    } catch {
      // ignore malformed env
    }
  }
  return [...origins]
}

// Explicit third-party origins the client actually connects to, instead of a blanket https:/wss:
// which would let a compromised bundle exfiltrate anywhere. Keep in sync with the wallet stack.
const thirdPartyConnectOrigins = [
  "https://eth.merkle.io",
  "https://ethereum.reth.rs",
  "https://*.walletconnect.com",
  "https://*.walletconnect.org",
  "wss://relay.walletconnect.com",
  "wss://relay.walletconnect.org",
  "https://api.web3modal.org",
  "https://*.reown.com",
  "https://*.coinbase.com",
  "wss://*.coinbase.com",
]

/**
 * Build the CSP header value.
 * @param {{ nonce?: string, isDev?: boolean }} opts
 */
export function buildContentSecurityPolicy({ nonce, isDev = false } = {}) {
  const connectSrc = [
    "'self'",
    ...convexConnectOrigins(),
    ...thirdPartyConnectOrigins,
    // Dev only: local Convex (http/ws on 127.0.0.1), the Next dev/HMR websocket, and blob: workers.
    ...(isDev ? ["ws:", "http:", "blob:"] : []),
  ].join(" ")

  // Production: nonce + strict-dynamic (no 'unsafe-inline'). The nonce'd bootstrap loads the
  // chunked scripts (strict-dynamic), and 'self' is the fallback for browsers without
  // strict-dynamic support. Dev keeps 'unsafe-inline'/'unsafe-eval' for Next HMR.
  const scriptSrc = isDev
    ? "script-src 'self' 'unsafe-inline' 'unsafe-eval'"
    : `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'`

  return [
    "default-src 'self'",
    scriptSrc,
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob: https:",
    "font-src 'self' data:",
    `connect-src ${connectSrc}`,
    "media-src 'self'",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    // WalletConnect frames verify.walletconnect.{com,org} during connect — allow those.
    "frame-src 'self' https://verify.walletconnect.com https://verify.walletconnect.org",
    "frame-ancestors 'none'",
  ].join("; ")
}
