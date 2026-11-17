import { describe, expect, it } from "vitest"
import { applyDetailContentOverlay } from "../live-detail-helpers"

const detail = {
  about: { description: "Base text.", stats: [], history: [] },
  faqs: [],
} as unknown as Parameters<typeof applyDetailContentOverlay>[0]

describe("About text from listing content", () => {
  it("shows the listing's full text when it gives one, else its description", () => {
    const content = { description: "Short.", stats: [], history: [], faqs: [] }
    expect(applyDetailContentOverlay(detail, { ...content, longText: "The full story." }).about.description).toBe("The full story.")
    expect(applyDetailContentOverlay(detail, content).about.description).toBe("Short.")
  })
})
