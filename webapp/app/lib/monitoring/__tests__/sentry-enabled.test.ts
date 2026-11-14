import { afterEach, describe, expect, it, vi } from "vitest"
import { isSentryEnabled } from "@/app/lib/monitoring/sentry-enabled"
import { sentryDeploymentFlag } from "@/app/lib/monitoring/sentry-deployment-flag.mjs"

afterEach(() => vi.unstubAllEnvs())

describe("Sentry reporting gate", () => {
  it("reports from a production build deployed on Vercel", () => {
    vi.stubEnv("NODE_ENV", "production")
    vi.stubEnv("NEXT_PUBLIC_AVANA_SENTRY_DEPLOYED", "1")
    expect(isSentryEnabled()).toBe(true)
  })

  it("stays quiet for a local production build (next build / next start on a laptop)", () => {
    vi.stubEnv("NODE_ENV", "production")
    vi.stubEnv("NEXT_PUBLIC_AVANA_SENTRY_DEPLOYED", "0")
    expect(isSentryEnabled()).toBe(false)
  })

  it("stays quiet in development", () => {
    vi.stubEnv("NODE_ENV", "development")
    vi.stubEnv("NEXT_PUBLIC_AVANA_SENTRY_DEPLOYED", "1")
    expect(isSentryEnabled()).toBe(false)
  })

  it("derives the build flag from Vercel's build environment", () => {
    expect(sentryDeploymentFlag({ VERCEL: "1" })).toBe("1")
    expect(sentryDeploymentFlag({})).toBe("0")
  })
})
