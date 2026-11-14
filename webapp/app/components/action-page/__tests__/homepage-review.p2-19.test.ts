import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"

describe("homepage embedded review footer", () => {
  it("P2-19: keeps action-footer-primary on review CTAs and renders review metric values visibly", () => {
    const footer = readFileSync(resolve(__dirname, "../../action-page/action-amount-card.tsx"), "utf8")
    const metrics = readFileSync(resolve(__dirname, "../../action-page/action-metrics.tsx"), "utf8")
    expect(footer).toMatch(/data-testid="action-footer-primary"/)
    expect(metrics).toMatch(/animateOnMount=\{false\}/)
  })
})
