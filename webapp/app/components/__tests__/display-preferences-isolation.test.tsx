import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import {
  DisplayPreferencesProvider,
  useAmountDisplayPreferences,
  useLocaleDisplayPreferences,
} from "@/app/components/display-preferences"

vi.mock("@/app/lib/currency/exchange-rates", () => ({
  applyCachedLiveRates: vi.fn(),
  fetchLiveRates: vi.fn(async () => false),
}))

let amountRenders = 0
let localeRenders = 0

function AmountProbe() {
  amountRenders += 1
  const { showDollarAmounts, toggleShowDollarAmounts } = useAmountDisplayPreferences()
  return <button onClick={toggleShowDollarAmounts}>{String(showDollarAmounts)}</button>
}

function LocaleProbe() {
  localeRenders += 1
  const { language, setLanguage } = useLocaleDisplayPreferences()
  return <button onClick={() => setLanguage("ES")}>{language}</button>
}

describe("DisplayPreferencesProvider subscription isolation", () => {
  afterEach(cleanup)

  beforeEach(() => {
    amountRenders = 0
    localeRenders = 0
    window.localStorage.clear()
  })

  it("does not re-render locale consumers for amount visibility updates", () => {
    render(
      <DisplayPreferencesProvider>
        <AmountProbe />
        <LocaleProbe />
      </DisplayPreferencesProvider>,
    )
    const initialLocaleRenders = localeRenders

    fireEvent.click(screen.getByRole("button", { name: "true" }))

    expect(screen.getByRole("button", { name: "false" })).toBeInTheDocument()
    expect(localeRenders).toBe(initialLocaleRenders)
  })

  it("does not re-render amount consumers for locale updates", () => {
    render(
      <DisplayPreferencesProvider>
        <AmountProbe />
        <LocaleProbe />
      </DisplayPreferencesProvider>,
    )
    const initialAmountRenders = amountRenders

    fireEvent.click(screen.getByRole("button", { name: "EN" }))

    expect(screen.getByRole("button", { name: "ES" })).toBeInTheDocument()
    expect(amountRenders).toBe(initialAmountRenders)
  })
})
