import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { PoolPickerDialog } from "@/app/components/home/pool-picker-dialog"
import type { HomeCollateralPool } from "@/app/lib/home-view-model"

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

afterEach(cleanup)

describe("PoolPickerDialog", () => {
  it.each([
    ["remove", "Select collateral position"],
    ["repay", "Select debt position"],
  ] as const)("P1-29 closes the %s picker overlay after selection", (mode, title) => {
    const onOpenChange = vi.fn()
    render(
      <PoolPickerDialog
        open
        onOpenChange={onOpenChange}
        selectedPoolId=""
        onSelect={() => undefined}
        mode={mode}
        pools={[pool]}
        debts={{ "eth-usdc": 500 }}
      />,
    )

    expect(screen.getByRole("dialog", { name: title })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: /WETH \/ USDC/i }))
    expect(onOpenChange).toHaveBeenCalledWith(false)
  })
})
