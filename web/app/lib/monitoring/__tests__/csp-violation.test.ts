import { describe, expect, it } from "vitest"
import { describeBlockedEval } from "../csp-violation"

const violation = {
  disposition: "enforce" as const,
  blockedURI: "eval",
  effectiveDirective: "script-src",
  sourceFile: "https://user:password@app.avana.cc/_next/static/chunks/wallet.js?token=secret#private",
  lineNumber: 234,
  columnNumber: 30,
}

describe("blocked eval diagnostics", () => {
  it("preserves the caller location without credentials or query data", () => {
    expect(describeBlockedEval(violation)).toEqual({
      source_file: "https://app.avana.cc/_next/static/chunks/wallet.js",
      line_number: 234,
      column_number: 30,
      directive: "script-src",
    })
  })

  it("keeps third-party script hosts the page loaded", () => {
    expect(describeBlockedEval({ ...violation, sourceFile: "https://cdn.example.com/sdk.js?v=1" })?.source_file).toBe(
      "https://cdn.example.com/sdk.js",
    )
  })

  // Production showed every report here came from wallet extensions (e.g. Backpack) injecting
  // code with no source file; the bundle ships no eval, so these are not actionable.
  it.each([
    "",
    "<anonymous>",
    "data:text/javascript,private-code",
    "chrome-extension://wallet/injected.js",
    "moz-extension://wallet/injected.js",
    "safari-web-extension://wallet/injected.js",
  ])("ignores evals without an http(s) script source: %s", (sourceFile) => {
    expect(describeBlockedEval({ ...violation, sourceFile })).toBeNull()
  })

  it("ignores report-only and unrelated policy events", () => {
    expect(describeBlockedEval({ ...violation, disposition: "report" })).toBeNull()
    expect(describeBlockedEval({ ...violation, blockedURI: "inline" })).toBeNull()
    expect(describeBlockedEval({ ...violation, effectiveDirective: "connect-src" })).toBeNull()
  })
})
