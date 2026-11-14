import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { DisplayPreferencesProvider } from "@/app/components/display-preferences"
import { isValidAction, isValidActionProduct } from "@/app/lib/action-system/contracts"
import { ActionNotFound } from "@/app/components/action-page/action-not-found"

describe("action validation", () => {
  it("rejects unknown products and kinds", () => {
    expect(isValidActionProduct("nonsense")).toBe(false)
    expect(isValidAction("borrow", "frobnicate")).toBe(false)
    expect(isValidAction("nonsense", "borrow")).toBe(false)
  })

  it("renders a graceful fallback with a way back", () => {
    render(
      <DisplayPreferencesProvider>
        <ActionNotFound closeHref="/lend" />
      </DisplayPreferencesProvider>,
    )
    expect(screen.getByTestId("action-not-found")).toBeTruthy()
    const back = screen.getByRole("link", { name: /go back/i }) as HTMLAnchorElement
    expect(back.getAttribute("href")).toBe("/lend")
  })
})
