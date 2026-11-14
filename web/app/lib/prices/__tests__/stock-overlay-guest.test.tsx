import { describe, it, expect, vi, beforeEach } from "vitest"
import { render } from "@testing-library/react"

const { fetchStockPrices } = vi.hoisted(() => ({ fetchStockPrices: vi.fn(async () => true) }))

vi.mock("@/app/lib/prices/stock-prices", () => ({
  fetchStockPrices,
  applyCachedStockPrices: () => false,
  STOCK_PRICE_REFRESH_MS: 300000,
  STOCK_PRICES_UPDATED_EVENT: "avana:stock-prices-updated",
}))

import { TokenPricesProvider } from "@/app/lib/prices/token-prices-context"

// Guests (realtime off) never see stock cells — product routes are wallet-gated — so the
// stock-price overlay must not mount and fire an unused fetch + a forever-running poll timer.
describe("StockPriceOverlay is not mounted on the guest path", () => {
  beforeEach(() => fetchStockPrices.mockClear())

  it("does not fetch stock prices when realtime is off", () => {
    render(<TokenPricesProvider realtime={false}>hi</TokenPricesProvider>)
    expect(fetchStockPrices).not.toHaveBeenCalled()
  })
})
