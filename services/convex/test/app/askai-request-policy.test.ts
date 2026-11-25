// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { expect, it } from "vitest"
import { askAIInstructions, askAIRequestPolicy } from "../../convex/lib/askAI/requestPolicy"
it("uses standard service unless explicitly configured otherwise", () => {
  expect(askAIRequestPolicy({}).serviceTier).toBe("default")
  expect(askAIRequestPolicy({ ASK_AI_SERVICE_TIER: "fast" }).serviceTier).toBe("fast")
  expect(() => askAIRequestPolicy({ ASK_AI_SERVICE_TIER: "typo" })).toThrow()
})
it("keeps wallet data outside the shared cache prefix", () => {
  const first = askAIInstructions("Shared policy", "wallet A")
  const second = askAIInstructions("Shared policy", "wallet B")
  expect(first[0]).toEqual(second[0])
  expect(first[1]!.providerOptions).toBeUndefined()
  expect(first[1]!.content).toBe("wallet A")
  expect(second[1]!.content).toBe("wallet B")
})
