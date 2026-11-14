import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { HomeActionContextBar } from "@/app/components/home/home-action-context-bar"
import type { HomeCollateralPool } from "@/app/lib/home-sim"

const pool: HomeCollateralPool = {
  id: "eth-usdc",
  name: "WETH / USDC",
  venue: "Uniswap",
  category: "Bluechip",
  collateralUsd: 4_200,
  maxLtv: 70,
  borrowPowerUsd: 2_940,
  liquidationUsd: 3_360,
  pairApr: 8.7,
  visuals: [
    { symbol: "WETH", shortLabel: "W", bgClassName: "bg-indigo-100", textClassName: "text-indigo-600" },
    { symbol: "USDC", shortLabel: "U", bgClassName: "bg-sky-100", textClassName: "text-sky-700" },
  ],
}

describe("HomeActionContextBar", () => {
  afterEach(() => {
    cleanup()
  })

  it("shows the selected collateral value in card mode", () => {
    render(<HomeActionContextBar pool={pool} onOpenPool={() => undefined} />)

    expect(screen.getByText("$4,200")).toBeInTheDocument()
  })

  it("shows the selected collateral value in inset mode and keeps the picker interactive", () => {
    const onOpenPool = vi.fn()
    render(<HomeActionContextBar pool={pool} onOpenPool={onOpenPool} variant="inset" />)

    expect(screen.getByText("$4,200")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: /WETH \/ USDC/i }))
    expect(onOpenPool).toHaveBeenCalledTimes(1)
  })
})
