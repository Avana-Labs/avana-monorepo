import { fireEvent, render } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { HotMarkets } from "../hot-markets"
import type { LendPageData } from "@/app/lib/data/providers/lend"

vi.mock("@/app/lib/i18n/use-translation", () => ({ useTranslation: () => ({ t: (key: string) => key, language: "en" }) }))

const assets = {
  "ethereum-gho": {
    id: "ethereum-gho",
    symbol: "GHO",
    displayName: "Gho Token",
    eyebrow: "Stablecoin",
    apy: 2.92,
    tone: "green",
    iconUrl: "/icons/gho.svg",
    path: "M0,60L396,0",
    values: [1.25, 4.5],
  },
} as unknown as LendPageData["featuredAssets"]

describe("HotMarkets tooltip with a recorded series", () => {
  it("shows the recorded APY of the hovered point", () => {
    const { container } = render(<HotMarkets assets={assets} sequence={["ethereum-gho"]} />)
    const card = container.querySelector("[data-featured-card]")!
    card.getBoundingClientRect = () => ({ left: 0, top: 0, width: 396, height: 176, right: 396, bottom: 176, x: 0, y: 0, toJSON: () => ({}) })
    fireEvent.mouseMove(card, { clientX: 0, clientY: 10 })
    expect(container.textContent).toContain("1.25%")
    fireEvent.mouseMove(card, { clientX: 396, clientY: 10 })
    expect(container.textContent).toContain("4.50%")
  })
})
