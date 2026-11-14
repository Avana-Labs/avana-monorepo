import { describe, expect, it } from "vitest"
import { enforceAskAIOutputPolicy } from "../output-policy"

describe("Ask AI output policy", () => {
  it("removes emoji and dash punctuation without damaging product hyphens", () => {
    expect(enforceAskAIOutputPolicy("Totally! 💛 WETH-USDC is fresh — APY is 4.2%.")).toBe(
      "Totally! WETH-USDC is fresh, APY is 4.2%.",
    )
  })

  it.each([
    "Want me to also check another market?",
    "Would you like me to compare rates?",
    "I can also review your portfolio.",
  ])("drops opt-in endings: %s", (ending) => {
    expect(enforceAskAIOutputPolicy(ending)).toBe("")
  })

  it("drops a conversational follow-up question after a greeting", () => {
    expect(enforceAskAIOutputPolicy("What can I help you with today?")).toBe("")
  })

  it("keeps a direct answer that contains an ordinary question mark", () => {
    expect(enforceAskAIOutputPolicy("Why is it lower? Utilization fell.")).toBe("Why is it lower? Utilization fell.")
  })
})
