import { expect, it } from "vitest"
import { baselineFailures } from "../../scripts/dependency-baseline.mjs"
const report = {
  metadata: { vulnerabilities: {} },
  vulnerabilities: {
    next: { name: "next", severity: "critical", via: [{ url: "https://github.com/advisories/example" }] },
  },
}
it("blocks an existing critical dependency regardless of the PR diff", () => {
  expect(baselineFailures(report)).toEqual(["next: critical"])
  expect(() => baselineFailures({ error: "offline" })).toThrow(/valid/)
})
it("requires a matching, justified, unexpired exception", () => {
  const exception = {
    package: "next",
    advisory: "https://github.com/advisories/example",
    reason: "Assessed fixture",
    expires: "2030-01-01",
  }
  expect(baselineFailures(report, [exception], Date.parse("2026-09-09"))).toEqual([])
  expect(() => baselineFailures(report, [exception], Date.parse("2031-01-01"))).toThrow(/expired/)
  expect(baselineFailures(report, [{ ...exception, package: "other" }], Date.parse("2026-09-09"))).toHaveLength(1)
})
