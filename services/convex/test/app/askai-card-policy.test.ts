// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { describe, expect, it } from "vitest"
import { portfolioCardFor } from "../../convex/lib/askAI/cardPolicy"

describe("portfolioCardFor", () => {
  it.each([
    "What is my exact net value and the four canonical component values? Show the numbers that reconcile to the total.",
    "What is my net value?",
    "How much do I have in Lend?",
    "What's my biggest position?",
    "Am I at risk of liquidation?",
    "",
  ])("answers in text only: %s", (question) => {
    expect(portfolioCardFor(question).show).toBe(false)
  })

  it.each([
    "Show me my portfolio",
    "List my positions",
    "Give me a breakdown of my portfolio",
    "Portfolio overview",
    "What's in my portfolio?",
    "What do I hold?",
  ])("shows the table: %s", (question) => {
    expect(portfolioCardFor(question)).toEqual({ show: true, includeUmbrella: false })
  })

  it("adds Umbrella rows only when Umbrella or all positions are asked for", () => {
    expect(portfolioCardFor("Show my positions including Umbrella").includeUmbrella).toBe(true)
    expect(portfolioCardFor("Show all my positions").includeUmbrella).toBe(true)
    expect(portfolioCardFor("Show my portfolio").includeUmbrella).toBe(false)
  })
})
