import { afterEach, describe, expect, it, vi } from "vitest"

describe("open gate test mode", () => {
  afterEach(() => {
    vi.unstubAllEnvs()
    vi.resetModules()
  })

  it("NEVER opens in a production build, even if every flag is set (deploy safety)", async () => {
    vi.stubEnv("NODE_ENV", "production")
    vi.stubEnv("NEXT_PUBLIC_DEV_OPEN_GATE", "1")
    vi.stubEnv("NEXT_PUBLIC_PLAYWRIGHT_TEST_MODE", "1")
    vi.stubEnv("NEXT_PUBLIC_LIGHTHOUSE_AUDIT_MODE", "1")
    const prod = await import("@/app/lib/test-mode")
    expect(prod.IS_OPEN_GATE_TEST_MODE).toBe(false)
    expect(prod.shouldUseOpenGateSession()).toBe(false)
  })

  it("opens in development for the Playwright e2e flag", async () => {
    vi.stubEnv("NODE_ENV", "development")
    vi.stubEnv("NEXT_PUBLIC_DEV_OPEN_GATE", "0")
    vi.stubEnv("NEXT_PUBLIC_PLAYWRIGHT_TEST_MODE", "1")
    const e2e = await import("@/app/lib/test-mode")
    expect(e2e.IS_OPEN_GATE_TEST_MODE).toBe(true)
    expect(e2e.shouldUseOpenGateSession()).toBe(true)
  })

  it("opens in development for the Lighthouse audit flag", async () => {
    vi.stubEnv("NODE_ENV", "development")
    vi.stubEnv("NEXT_PUBLIC_DEV_OPEN_GATE", "0")
    vi.stubEnv("NEXT_PUBLIC_PLAYWRIGHT_TEST_MODE", "0")
    vi.stubEnv("NEXT_PUBLIC_LIGHTHOUSE_AUDIT_MODE", "1")
    const audit = await import("@/app/lib/test-mode")
    expect(audit.IS_OPEN_GATE_TEST_MODE).toBe(true)
    expect(audit.shouldUseOpenGateSession()).toBe(true)
  })

  it("never opens the gate in a production build, even with the Lighthouse audit vars set", async () => {
    // SECURITY: the audit vars are NEXT_PUBLIC_ (bakeable into a shippable client bundle), so a
    // production runtime must never auto-open the dev gate / auto-mint the test JWT. The local
    // audit still works because its routes render the static LighthouseAuditSurface via
    // isLighthouseAuditMode(), which is independent of the open-gate session.
    vi.stubEnv("NODE_ENV", "production")
    vi.stubEnv("NEXT_PUBLIC_LIGHTHOUSE_AUDIT_MODE", "1")
    vi.stubEnv("NEXT_PUBLIC_LIGHTHOUSE_AUDIT_ARTIFACT", "1")
    vi.stubEnv("VERCEL", "")
    vi.stubEnv("CI", "")
    const audit = await import("@/app/lib/test-mode")
    expect(audit.shouldUseOpenGateSession()).toBe(false)
    expect(audit.isLighthouseAuditMode()).toBe(true)
  })
})
