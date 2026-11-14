import { describe, expect, it } from "vitest"
import { processingNarrationScript } from "@/app/components/action-page/processing-narration"
import { getProcessingTitle } from "@/app/lib/action-system/action-page-labels"

describe("processingNarrationScript", () => {
  // Every descriptor verb (contracts.ts) maps to its own apt script, keyed by a line
  // unique to that script. Guards the "Supply"->pledge and "Deleverage"->deleverage
  // fixes so they never regress into the lend-deposit / loop narratives.
  const cases: Array<[string, string]> = [
    ["Borrow", "Opening your credit line"],
    ["Repay", "Freeing up your borrowing power"],
    ["Supply", "Pledging collateral on Aave v4"],
    ["Remove", "Unlocking your collateral"],
    ["Claim", "Signing your claim"],
    ["Deposit", "Minting your yield position"],
    ["Withdraw", "Unwinding your supplied position"],
    ["Multiply", "Locking in your leverage"],
    ["Deleverage", "Unwinding part of your loop"],
    ["Swap", "Connecting to the swap router"],
  ]

  it.each(cases)("maps the %s verb to its own script", (verb, distinctiveLine) => {
    expect(processingNarrationScript(verb)).toContain(distinctiveLine)
  })

  it("falls back to a generic script for an unrecognized verb", () => {
    expect(processingNarrationScript("Frobnicate")).toContain("Confirming on-chain")
  })

  it("gives every action a readable, multi-line script", () => {
    for (const [verb] of cases) {
      expect(processingNarrationScript(verb)).toHaveLength(5)
    }
  })

  it("uses the correct present participle for swap", () => {
    expect(getProcessingTitle("Swap", "ETH")).toBe("Swapping ETH")
  })
})
