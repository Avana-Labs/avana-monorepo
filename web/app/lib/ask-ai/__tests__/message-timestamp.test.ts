import { describe, expect, it } from "vitest"
import { formatAskAIMessageTimestamp } from "../message-timestamp"

describe("formatAskAIMessageTimestamp", () => {
  const now = new Date(2026, 7, 22, 10, 30)

  it("shows only the time for messages from today", () => {
    expect(formatAskAIMessageTimestamp(new Date(2026, 7, 22, 8, 41), now)).toBe("8:41 AM")
  })

  it("labels messages from yesterday", () => {
    expect(formatAskAIMessageTimestamp(new Date(2026, 7, 21, 20, 41), now)).toBe("Yesterday, 8:41 PM")
  })

  it("shows the date and time for older messages", () => {
    expect(formatAskAIMessageTimestamp(new Date(2026, 7, 20, 20, 41), now)).toBe("Aug 20, 8:41 PM")
  })

  it("includes the year for messages from another year", () => {
    expect(formatAskAIMessageTimestamp(new Date(2025, 11, 31, 20, 41), now)).toBe("Dec 31, 2025, 8:41 PM")
  })
})
