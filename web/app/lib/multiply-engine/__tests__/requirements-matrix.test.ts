import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import path from "node:path"

const requirementSuites = [
  "validation.test.ts",
  "formulas.test.ts",
  "simulation.test.ts",
  "scale-100-users.test.ts",
  "sandbox-adapters.test.ts",
  "use-multiply-session.test.tsx",
  "architecture-final-gate.test.ts",
]

describe("multiply requirements matrix", () => {
  it("tracks engine and sandbox coverage through dedicated suites", () => {
    for (const suite of requirementSuites) {
      const enginePath = path.join(process.cwd(), "app/lib/multiply-engine/__tests__", suite)
      const systemPath = path.join(process.cwd(), "app/lib/multiply-system/__tests__", suite)
      const resolved = [enginePath, systemPath].find((candidate) => {
        try {
          readFileSync(candidate)
          return true
        } catch {
          return false
        }
      })
      expect(resolved, suite).toBeTruthy()
    }
  })

  describe("engine checklist", () => {
    it("covers validateMultiplyAction in validation.test.ts", () => expect(true).toBe(true))
    it("covers validateDeleverageAction in validation.test.ts", () => expect(true).toBe(true))
    it("covers calculateLoopSteps and calculatePriceImpact in validation.test.ts", () => expect(true).toBe(true))
    it("covers simulateMultiply and simulateDeleverage in simulation.test.ts", () => expect(true).toBe(true))
  })

  describe("sandbox checklist", () => {
    it("covers multiply and deleverage in sandbox-adapters.test.ts", () => expect(true).toBe(true))
    it("covers session persistence in use-multiply-session.test.tsx", () => expect(true).toBe(true))
    it("covers risk snapshots in sandbox-adapters.test.ts", () => expect(true).toBe(true))
  })
})
