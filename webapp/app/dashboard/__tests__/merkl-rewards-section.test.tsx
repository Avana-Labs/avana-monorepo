import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { MerklRewardsSection } from "../_rewards-components/merkl-rewards-section"

describe("Merkl rewards section", () => {
  it("shows the coming-soon state, not reward amounts", () => {
    render(<MerklRewardsSection />)
    expect(screen.getByRole("region", { name: "Merkl Rewards" })).toBeInTheDocument()
    expect(screen.getByText("Coming soon")).toBeInTheDocument()
  })
})
