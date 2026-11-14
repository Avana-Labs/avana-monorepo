import { useState } from "react"
import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { CurrencyDisplayBoundary } from "../currency-display-boundary"
import { applyLiveRates } from "@/app/lib/currency/rates"

const preferences = vi.hoisted(() => ({ currency: "USD", ratesVersion: 0 }))
vi.mock("../display-preferences", () => ({ useLocaleDisplayPreferences: () => preferences }))
afterEach(() => {
  cleanup()
  preferences.currency = "USD"
  preferences.ratesVersion = 0
})

function Draft() {
  const [value, setValue] = useState("")
  return <input aria-label="Draft" value={value} onChange={(event) => setValue(event.target.value)} />
}
function Page() {
  return (
    <CurrencyDisplayBoundary>
      <Draft />
    </CurrencyDisplayBoundary>
  )
}

describe("currency page lifetime", () => {
  it("preserves the USD page when foreign exchange rates refresh", () => {
    const { rerender } = render(<Page />)
    fireEvent.change(screen.getByLabelText("Draft"), { target: { value: "unfinished question" } })
    applyLiveRates({ EUR: 0.88 })
    preferences.ratesVersion++
    rerender(<Page />)
    expect(screen.getByLabelText("Draft")).toHaveValue("unfinished question")
  })

  it("preserves a foreign-currency page when its effective rate is unchanged", () => {
    preferences.currency = "EUR"
    applyLiveRates({ EUR: 0.9 })
    const { rerender } = render(<Page />)
    fireEvent.change(screen.getByLabelText("Draft"), { target: { value: "100" } })
    applyLiveRates({ EUR: 0.9, GBP: 0.8 })
    preferences.ratesVersion++
    rerender(<Page />)
    expect(screen.getByLabelText("Draft")).toHaveValue("100")

    applyLiveRates({ EUR: 0.95 })
    preferences.ratesVersion++
    rerender(<Page />)
    expect(screen.getByLabelText("Draft")).toHaveValue("")
  })

  it("still refreshes module-based displays after changing currency", () => {
    const { rerender } = render(<Page />)
    fireEvent.change(screen.getByLabelText("Draft"), { target: { value: "100" } })
    preferences.currency = "GBP"
    rerender(<Page />)
    expect(screen.getByLabelText("Draft")).toHaveValue("")
  })
})
