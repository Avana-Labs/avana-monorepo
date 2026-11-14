import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

describe("LearnSection (Learn Avana explainers)", () => {
  it("P2-06: renders full-card explainers with no outbound links", () => {
    const source = readFileSync(resolve(__dirname, "../learn-section.tsx"), "utf8")
    // The Learn section is now a teaching-card grid ("Learn Avana"), like Learn
    // Umbrella — icon + title + body, with no blog / external links.
    expect(source).toMatch(/Learn Avana/)
    expect(source).not.toMatch(/AVANA_EXTERNAL_LINKS/)
    expect(source).not.toMatch(/href=/)
    expect(source).not.toMatch(/avana-ashen\.vercel\.app/)
  })
})
