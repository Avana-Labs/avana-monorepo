import { describe, expect, it } from "vitest"
import { dayPartFromLocalHour, firstNameFromDisplayName, formatAskAIGreeting } from "../greeting"

describe("dayPartFromLocalHour", () => {
  it("maps local hours to greeting buckets", () => {
    expect(dayPartFromLocalHour(5)).toBe("morning")
    expect(dayPartFromLocalHour(11)).toBe("morning")
    expect(dayPartFromLocalHour(12)).toBe("afternoon")
    expect(dayPartFromLocalHour(16)).toBe("afternoon")
    expect(dayPartFromLocalHour(17)).toBe("evening")
    expect(dayPartFromLocalHour(21)).toBe("evening")
    expect(dayPartFromLocalHour(22)).toBe("late")
    expect(dayPartFromLocalHour(3)).toBe("late")
  })
})

describe("firstNameFromDisplayName", () => {
  it("uses the first token and ignores blanks", () => {
    expect(firstNameFromDisplayName("Josue")).toBe("Josue")
    expect(firstNameFromDisplayName("  Josue  Perez ")).toBe("Josue")
    expect(firstNameFromDisplayName("")).toBeNull()
    expect(firstNameFromDisplayName("   ")).toBeNull()
    expect(firstNameFromDisplayName(undefined)).toBeNull()
  })
})

describe("formatAskAIGreeting", () => {
  it("includes the first name for daytime greetings", () => {
    const morning = formatAskAIGreeting("Josue", new Date(2026, 7, 23, 9, 0, 0))
    expect(morning).toMatch(/Josue/)
    expect(morning.split(/\s+/).length).toBeLessThanOrEqual(7)
  })

  it("avoids awkward late-night time labels", () => {
    const late = formatAskAIGreeting("Josue", new Date(2026, 7, 23, 23, 30, 0))
    expect(late).toMatch(/Josue/)
    expect(late.toLowerCase()).not.toMatch(/morning|afternoon|evening/)
  })

  it("falls back to a nameless greeting when name is missing", () => {
    const greeting = formatAskAIGreeting(null, new Date(2026, 7, 23, 14, 0, 0))
    expect(greeting).not.toMatch(/\{name\}/)
    expect(greeting.length).toBeGreaterThan(0)
  })

  it("stays stable for the same day and day-part", () => {
    const a = formatAskAIGreeting("Alex", new Date(2026, 7, 23, 10, 15, 0))
    const b = formatAskAIGreeting("Alex", new Date(2026, 7, 23, 10, 45, 0))
    expect(a).toBe(b)
  })
})
