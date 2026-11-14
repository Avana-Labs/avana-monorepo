import { expect, it } from "vitest"
import { askAIInstructions, askAIRequestPolicy } from "../request-policy"
it("uses standard service unless explicitly configured otherwise", () => {
  expect(askAIRequestPolicy({}).serviceTier).toBe("default")
  expect(askAIRequestPolicy({ ASK_AI_SERVICE_TIER: "fast" }).serviceTier).toBe("fast")
  expect(() => askAIRequestPolicy({ ASK_AI_SERVICE_TIER: "typo" })).toThrow()
})
it("keeps wallet data outside the shared cache prefix", () => {
  const first = askAIInstructions("Shared policy", "wallet A")
  const second = askAIInstructions("Shared policy", "wallet B")
  expect(first[0]).toEqual(second[0])
  expect(first[1].providerOptions).toBeUndefined()
  expect(first[1].content).toBe("wallet A")
  expect(second[1].content).toBe("wallet B")
})
