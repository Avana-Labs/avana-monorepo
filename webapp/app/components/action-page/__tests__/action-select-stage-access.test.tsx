import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { ActionSelectStage } from "@/app/components/action-page/action-select-stage"
import { TransactAccessContext } from "@/app/lib/transact-access"

vi.mock("@/app/lib/i18n/use-translation", () => ({ useTranslation: () => ({ t: (key: string) => key }) }))

// Prod 2026-09-23: a guest on Lend → Deposit saw "No assets in your wallet" with no next step.
describe("ActionSelectStage empty state access", () => {
  afterEach(() => cleanup())

  it("offers Get Started to a guest with an empty list", () => {
    render(
      <TransactAccessContext.Provider value="guest">
        <ActionSelectStage items={[]} onSelect={() => {}} emptyTitle="No assets in your wallet" />
      </TransactAccessContext.Provider>,
    )
    expect(screen.getByRole("link", { name: "Get Started" })).toHaveAttribute("href", "/dashboard")
  })

  it("shows no CTA to a signed-in wallet", () => {
    render(<ActionSelectStage items={[]} onSelect={() => {}} />)
    expect(screen.queryByRole("link")).toBeNull()
  })
})
