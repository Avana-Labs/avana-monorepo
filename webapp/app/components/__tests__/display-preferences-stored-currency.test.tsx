import { cleanup, render, screen, waitFor } from "@testing-library/react"
import { StrictMode } from "react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { DisplayPreferencesProvider } from "@/app/components/display-preferences"
import { setActiveCurrency, setActiveLocale } from "@/app/lib/currency/active-rate"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { formatCompactUsd } from "@/app/lib/borrow-market-rows"

vi.mock("@/app/lib/currency/exchange-rates", () => ({
  applyCachedLiveRates: vi.fn(),
  fetchLiveRates: vi.fn(async () => false),
}))

// A guest render: only the root DisplayPreferencesProvider, no wallet or session providers.
function MoneyProbe() {
  const currency = useCurrency()
  return (
    <div>
      <span data-testid="hook">{currency.compact(101_900_000)}</span>
      <span data-testid="shared">{formatCompactUsd(21_000_000)}</span>
    </div>
  )
}

function renderGuest() {
  return render(
    <StrictMode>
      <DisplayPreferencesProvider>
        <MoneyProbe />
      </DisplayPreferencesProvider>
    </StrictMode>,
  )
}

describe("DisplayPreferencesProvider stored currency", () => {
  afterEach(() => {
    cleanup()
    setActiveCurrency("USD")
    setActiveLocale("EN")
  })

  beforeEach(() => {
    window.localStorage.clear()
  })

  it("converts guest money values to a stored EUR preference and keeps it stored", async () => {
    window.localStorage.setItem("avana-currency", "EUR")
    window.localStorage.setItem("avana-language", "DE")
    window.localStorage.setItem("avana-show-dollar-amounts", "false")

    renderGuest()

    await waitFor(() => {
      expect(screen.getByTestId("hook").textContent).toMatch(/^€/)
      expect(screen.getByTestId("shared").textContent).toMatch(/^€/)
    })
    expect(screen.getByTestId("hook").textContent).not.toContain("$")
    expect(screen.getByTestId("shared").textContent).not.toContain("$")

    // The restore must not be followed by a write of the provider's defaults.
    expect(window.localStorage.getItem("avana-currency")).toBe("EUR")
    expect(window.localStorage.getItem("avana-language")).toBe("DE")
    expect(window.localStorage.getItem("avana-show-dollar-amounts")).toBe("false")
  })

  it("keeps a guest without a stored preference in USD", async () => {
    renderGuest()

    await waitFor(() => expect(window.localStorage.getItem("avana-currency")).toBe("USD"))
    expect(screen.getByTestId("hook")).toHaveTextContent("$101.9M")
    expect(screen.getByTestId("shared")).toHaveTextContent("$21.0M")
  })
})
