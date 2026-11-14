import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import {
  SectionCardActions,
  SectionCardCopy,
  SectionCardPrimaryMetric,
  SectionCardSupportingLabel,
} from "../SectionCard"

describe("SectionCard hierarchy", () => {
  it("keeps metrics, labels, copy, and actions visually distinct", () => {
    render(
      <div>
        <SectionCardPrimaryMetric>$12,400</SectionCardPrimaryMetric>
        <SectionCardSupportingLabel>Available liquidity</SectionCardSupportingLabel>
        <SectionCardCopy>Liquidity changes as borrowers use the market.</SectionCardCopy>
        <SectionCardActions>Action</SectionCardActions>
      </div>,
    )

    expect(screen.getByText("$12,400")).toHaveClass("text-[26px]", "font-medium")
    expect(screen.getByText("Available liquidity")).toHaveClass("text-[12px]", "text-muted-foreground")
    expect(screen.getByText(/Liquidity changes/)).toHaveClass("text-[15px]", "leading-[1.6]")
    expect(screen.getByText("Action")).toHaveClass("border-t", "pt-4")
  })
})
