import { fireEvent, render } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { HotMarkets } from "../hot-markets"
import type { LendPageData } from "@/app/lib/data/providers/lend"

const assets = {
  "ethereum-gho": {
    id: "ethereum-gho",
    symbol: "GHO",
    displayName: "Gho Token",
    eyebrow: "Stablecoin",
    apy: 2.92,
    tone: "green",
    iconUrl: "/icons/gho.svg",
  },
} as unknown as LendPageData["featuredAssets"]

describe("HotMarkets with no APY history", () => {
  it("hovering a featured card without a sparkline does not throw", () => {
    const { container } = render(<HotMarkets assets={assets} sequence={["ethereum-gho"]} />)
    const cards = container.querySelectorAll("[data-featured-card]")
    expect(cards.length).toBeGreaterThan(0)
    expect(() => fireEvent.mouseMove(cards[0], { clientX: 10, clientY: 10 })).not.toThrow()
    expect(container.textContent).toContain("Gho Token")
  })
})
