import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { ActionContextSelectorCard } from "@/app/components/action-page/action-context-selector-card"

vi.mock("@/app/lib/i18n/use-translation", () => ({ useTranslation: () => ({ t: (key: string) => key }) }))

// The Borrow review step offered the collateral dropdown after the quote was built for one pool.
describe("ActionContextSelectorCard lock", () => {
  afterEach(() => cleanup())

  it("is not clickable and hides the chevron when locked", () => {
    const onClick = vi.fn()
    render(
      <ActionContextSelectorCard
        label="Collateral"
        value="cbBTC / USDC"
        collateralSymbol="cbBTC"
        borrowSymbol="USDC"
        onClick={onClick}
        switchable={false}
      />,
    )
    const card = screen.getByTestId("action-context-selector-card")
    fireEvent.click(card)
    expect(onClick).not.toHaveBeenCalled()
    expect(card).toBeDisabled()
    expect(card.textContent).not.toContain("▾")
  })
})
