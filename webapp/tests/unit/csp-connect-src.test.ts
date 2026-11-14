import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { TARGET_CHAIN } from "../../app/lib/web3/target-chain"

async function resolveConnectSrc() {
  // The CSP is built in lib/content-security-policy.mjs (used by proxy.ts). connect-src reads
  // the Convex env at build time, so reset the module registry and re-import after stubbing env.
  vi.resetModules()
  const mod = await import("../../lib/content-security-policy.mjs")
  const csp = mod.buildContentSecurityPolicy({ nonce: "test-nonce", isDev: false })
  const directive = csp.split("; ").find((d) => d.startsWith("connect-src")) as string
  return directive.slice("connect-src ".length).split(" ")
}

describe("CSP connect-src (#137)", () => {
  beforeEach(() => {
    vi.stubEnv("NEXT_PUBLIC_CONVEX_URL", "https://example-app.convex.cloud")
    vi.stubEnv("NEXT_PUBLIC_CONVEX_SITE_URL", "https://example-app.convex.site")
  })

  afterEach(() => {
    vi.unstubAllEnvs()
    vi.resetModules()
  })

  it("does not allow blanket https: or wss:", async () => {
    const sources = await resolveConnectSrc()
    expect(sources).not.toContain("https:")
    expect(sources).not.toContain("wss:")
  })

  it("lists the explicit Convex origins in both transports so realtime works", async () => {
    const sources = await resolveConnectSrc()
    expect(sources).toContain("https://example-app.convex.cloud")
    expect(sources).toContain("wss://example-app.convex.cloud")
    expect(sources).toContain("https://example-app.convex.site")
    expect(sources).toContain("wss://example-app.convex.site")
  })

  it("keeps the wallet/RPC origins the client needs", async () => {
    const sources = await resolveConnectSrc()
    expect(sources).toContain("'self'")
    expect(sources).toContain("https://eth.merkle.io")
    expect(sources).toContain("wss://relay.walletconnect.org")
    expect(sources).toContain("https://*.coinbase.com")
  })

  it("allows the default RPC selected by the wallet transport", async () => {
    const sources = await resolveConnectSrc()
    for (const endpoint of TARGET_CHAIN.rpcUrls.default.http) {
      expect(sources).toContain(new URL(endpoint).origin)
    }
  })

  it("continues to block eval in production", async () => {
    const { buildContentSecurityPolicy } = await import("../../lib/content-security-policy.mjs")
    const csp = buildContentSecurityPolicy({ nonce: "test-nonce", isDev: false })
    expect(csp).not.toContain("'unsafe-eval'")
    expect(csp).toContain("'nonce-test-nonce' 'strict-dynamic'")
  })
})
