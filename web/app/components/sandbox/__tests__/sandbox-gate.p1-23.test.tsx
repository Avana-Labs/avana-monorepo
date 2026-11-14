import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

describe("SandboxGate first paint", () => {
  it("p1-23: renders the onboarding hero only on the signed-out branch, never as a pre-hydration guess", () => {
    const source = readFileSync(resolve(__dirname, "../sandbox-gate.tsx"), "utf8")
    // The SIWE store is seeded from the server-verified session cookie, so the gate must not carry a
    // "we don't know yet" hydration branch anymore: signed-out → guest hero; signed-in → host.
    expect(source).not.toMatch(/useHydrated/)
    const body = source.split("export function SandboxGate")[1] ?? ""
    const guestBranch = body.split("if (!isSignedIn || !authedWallet)")[1]?.split("return (")[1] ?? ""
    expect(guestBranch).toMatch(/<GuestOnboardingFlow/)
    // GuestOnboardingFlow must appear only inside that guard.
    const beforeGuard = body.split("if (!isSignedIn || !authedWallet)")[0] ?? ""
    expect(beforeGuard).not.toMatch(/<GuestOnboardingFlow/)
  })

  it("keeps the server-rendered product mounted while the Convex checker resolves", () => {
    const host = readFileSync(resolve(__dirname, "../signed-in-sandbox-gate.tsx"), "utf8")
    // Children render at a fixed position; the checker is a lazy SIBLING inside its own Suspense,
    // so its chunk arriving or its verdict changing never re-parents (remounts) the page.
    expect(host).toMatch(/\{showChildren \? children/)
    expect(host).toMatch(/<Suspense fallback=\{null\}>\s*<AuthedGateChecker/)
    expect(host).not.toMatch(/<AuthedGateChecker[^>]*>\s*\{children\}/)
  })

  it("keeps Convex behind the signed-in-only import boundary", () => {
    const source = readFileSync(resolve(__dirname, "../sandbox-gate.tsx"), "utf8")
    expect(source).toMatch(/import\("\.\/signed-in-sandbox-gate"\)/)
    expect(source).toMatch(/dynamic\(/)
    expect(source).not.toMatch(/from ["']convex\/react["']/)
    expect(source).not.toMatch(/siwe-convex-provider/)
    expect(source).not.toMatch(/\blazy\s*\(/)
  })

  it("does not block signed-in pages on the deferred wallet SDK", () => {
    const source = readFileSync(resolve(__dirname, "../sandbox-gate.tsx"), "utf8")
    expect(source).not.toMatch(/useWalletGate/)
    expect(source).not.toMatch(/walletActive/)
  })
})
