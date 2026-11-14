import { describe, expect, it, vi, afterEach } from "vitest"
import { cleanup, render, screen } from "@testing-library/react"
import { PriceFreshnessNotice } from "@/app/components/prices/price-freshness-notice"
import * as ctx from "@/app/lib/prices/token-prices-context"

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe("PriceFreshnessNotice (C4)", () => {
  it("renders nothing while prices are fresh", () => {
    vi.spyOn(ctx, "usePriceFreshness").mockReturnValue({ stale: false, updatedAt: Date.now(), ageMs: 0 })
    const { container } = render(<PriceFreshnessNotice />)
    expect(container).toBeEmptyDOMElement()
  })

  it("surfaces a stale warning when the oracle has aged past the threshold", () => {
    vi.spyOn(ctx, "usePriceFreshness").mockReturnValue({
      stale: true,
      updatedAt: Date.now() - 60 * 60 * 1000,
      ageMs: 60 * 60 * 1000,
    })
    render(<PriceFreshnessNotice />)
    expect(screen.getByRole("status")).toHaveTextContent(/stale/i)
  })
})
