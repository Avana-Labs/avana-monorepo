import { render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { HomeWorkspaceCard } from "../home-workspace-card"

vi.mock("@/app/lib/i18n/use-translation", () => ({
  useTranslation: () => ({ t: (value: string) => value }),
}))

describe("HomeWorkspaceCard", () => {
  it("shows the compact Testnet badge beside the action tabs", () => {
    render(
      <HomeWorkspaceCard mode="swap" onModeChange={() => undefined}>
        <div>Swap action</div>
      </HomeWorkspaceCard>,
    )

    expect(screen.getByText("Testnet")).toBeInTheDocument()
    expect(screen.getByText("Swap action")).toBeInTheDocument()
  })
})
