import { render, cleanup, within } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { BorrowableAssetsPanel } from "../borrowable-assets-table"
import type { BorrowableAsset } from "@/app/lib/data/borrow-domain"

const wbtc: BorrowableAsset = {
  id: "uni-v3-bluechip:wbtc",
  symbol: "WBTC",
  name: "Wrapped Bitcoin",
  subtitle: "BTC",
  borrowApr: 3.4,
  totalBorrowedUsd: 9_600_000,
  utilization: 62,
  availableUsd: 4_200_000,
  walletBalanceLabel: "0.00",
  hasWalletBalance: false,
  visual: { symbol: "WBTC", shortLabel: "W", bgClass: "bg-amber-100", textClass: "text-amber-700" },
  trendUp: true,
  category: "btc",
}

describe("BorrowableAssetsPanel loan variant", () => {
  afterEach(() => {
    cleanup()
  })

  it("labels TOTAL BORROWS and LIQUIDITY as USD, never as a token quantity", () => {
    const { container, getAllByText } = render(<BorrowableAssetsPanel rows={[wbtc]} onBorrow={vi.fn()} />)

    // USD figures render as currency, not as a bare number with a token symbol.
    expect(getAllByText("$9.6M").length).toBeGreaterThan(0)
    expect(getAllByText("$4.2M").length).toBeGreaterThan(0)

    // No cell mixes a USD magnitude with a token symbol (e.g. "9.6M WBTC").
    expect(container.textContent).not.toMatch(/9\.6M\s+WBTC/)
    expect(container.textContent).not.toMatch(/4\.2M\s+WBTC/)

    const capacityHeading = [...container.querySelectorAll("thead th button")].find((button) =>
      button.textContent?.includes("Capacity Filled"),
    )
    expect(capacityHeading).toBeDefined()
    // Shared SortHeaderButton: CSS uppercase on the button, never wraps.
    expect(capacityHeading).toHaveClass("!uppercase", "whitespace-nowrap")

    const borrowableRow = container.querySelector("tbody tr")
    expect(borrowableRow).not.toBeNull()
    const cells = within(borrowableRow as HTMLElement).getAllByRole("cell")
    expect(cells[3]).toHaveTextContent("$9.6M")
    expect(within(cells[3]).queryByRole("img")).not.toBeInTheDocument()
    expect(within(cells[4]).getByRole("img", { name: "Capacity filled 62%" })).toBeInTheDocument()
  })

  it("renders capacity filled as the rounded utilization gauge with the Borrow row action", () => {
    const raw: BorrowableAsset = { ...wbtc, utilization: 69.68000215736105 }
    const { getAllByRole, queryAllByRole } = render(<BorrowableAssetsPanel rows={[raw]} onBorrow={vi.fn()} />)

    expect(getAllByRole("img", { name: "Capacity filled 70%" }).length).toBeGreaterThan(0)
    expect(queryAllByRole("button", { name: "Deposit" })).toHaveLength(0)
    expect(getAllByRole("button", { name: "Borrow" }).length).toBeGreaterThan(0)
  })
})
