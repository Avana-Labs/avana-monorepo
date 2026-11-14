import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

describe("referral ref param", () => {
  it("p1-12: invite links land on the homepage with a ref query", () => {
    const adapter = readFileSync(resolve(__dirname, "../sandbox-action-adapter.ts"), "utf8")
    expect(adapter).toMatch(/https:\/\/avana\.cc\/\?ref=\$\{buildReferralCode\(wallet\)\}/)
  })

  it("p1-12: dashboard client applies referral code from searchParams on mount", () => {
    const dashboard = readFileSync(resolve(__dirname, "../../../dashboard/dashboard-page-client.tsx"), "utf8")
    expect(dashboard).toMatch(/searchParams\.get\(["']ref["']\)/)
    expect(dashboard).toMatch(/applyReferralCode/)
  })

  it("p1-12: homepage captures the ref param on load", () => {
    const home = readFileSync(resolve(__dirname, "../../../components/home-page-workspace-runtime.tsx"), "utf8")
    expect(home).toMatch(/URLSearchParams\(window\.location\.search\)\.get\(["']ref["']\)/)
    expect(home).toMatch(/applyReferralCode/)
  })
})
