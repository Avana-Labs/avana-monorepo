import { cleanup, render, screen, waitFor } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import {
  DisplayPreferencesProvider,
  useAmountDisplayPreferences,
  useLocaleDisplayPreferences,
} from "@/app/components/display-preferences"
import { getActiveCurrency, getActiveLocale } from "@/app/lib/currency/active-rate"

vi.mock("@/app/lib/currency/exchange-rates", () => ({
  applyCachedLiveRates: vi.fn(),
  fetchLiveRates: vi.fn(async () => false),
}))

function AmountProbe() {
  const { showDollarAmounts } = useAmountDisplayPreferences()
  return <span data-testid="amounts">{String(showDollarAmounts)}</span>
}

function LocaleProbe() {
  const { language, currency } = useLocaleDisplayPreferences()
  return (
    <div>
      <span data-testid="language">{language}</span>
      <span data-testid="currency">{currency}</span>
    </div>
  )
}

function firePreferenceStorage(key: string, newValue: string | null) {
  window.dispatchEvent(new StorageEvent("storage", { key, newValue }))
}

describe("DisplayPreferencesProvider cross-tab sync", () => {
  afterEach(cleanup)

  beforeEach(() => {
    window.localStorage.clear()
  })

  it("applies language, currency, and amount visibility from another tab", async () => {
    render(
      <DisplayPreferencesProvider>
        <AmountProbe />
        <LocaleProbe />
      </DisplayPreferencesProvider>,
    )

    await waitFor(() => expect(screen.getByTestId("language")).toHaveTextContent("EN"))

    window.localStorage.setItem("avana-language", "ES")
    firePreferenceStorage("avana-language", "ES")
    window.localStorage.setItem("avana-currency", "EUR")
    firePreferenceStorage("avana-currency", "EUR")
    window.localStorage.setItem("avana-show-dollar-amounts", "false")
    firePreferenceStorage("avana-show-dollar-amounts", "false")

    await waitFor(() => {
      expect(screen.getByTestId("language")).toHaveTextContent("ES")
      expect(screen.getByTestId("currency")).toHaveTextContent("EUR")
      expect(screen.getByTestId("amounts")).toHaveTextContent("false")
    })

    expect(document.documentElement.lang).toBe("es")
    expect(getActiveLocale()).toBe("es")
    expect(getActiveCurrency().currency).toBe("EUR")
  })

  it("ignores unrelated keys and invalid preference values", async () => {
    render(
      <DisplayPreferencesProvider>
        <AmountProbe />
        <LocaleProbe />
      </DisplayPreferencesProvider>,
    )

    await waitFor(() => expect(screen.getByTestId("language")).toHaveTextContent("EN"))

    firePreferenceStorage("unrelated-key", "x")
    firePreferenceStorage("avana-language", "ZZ")
    firePreferenceStorage("avana-currency", "XYZ")
    firePreferenceStorage("avana-show-dollar-amounts", "maybe")

    expect(screen.getByTestId("language")).toHaveTextContent("EN")
    expect(screen.getByTestId("currency")).toHaveTextContent("USD")
    expect(screen.getByTestId("amounts")).toHaveTextContent("true")
  })
})
