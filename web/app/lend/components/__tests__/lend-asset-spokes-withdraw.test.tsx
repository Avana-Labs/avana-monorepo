import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { LendAssetSpokes, paginateLendAssetGroups } from "@/app/lend/components/lend-asset-spokes"
import { LEND_ASSET_GROUPS } from "@/app/lib/data/catalog/lend"

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: vi.fn() }),
  useSearchParams: () => new URLSearchParams(),
}))
vi.mock("@/app/lib/prices/token-prices-context", () => ({
  usePriceFor: () => () => undefined,
  useCanonicalPriceFor: () => () => undefined,
}))

afterEach(cleanup)

describe("LendAssetSpokes capacity display and actions", () => {
  it("paginates globally while preserving asset groups", () => {
    const firstPage = paginateLendAssetGroups(LEND_ASSET_GROUPS, 0, 4)
    const secondPage = paginateLendAssetGroups(LEND_ASSET_GROUPS, 1, 4)

    expect(firstPage.flatMap((group) => group.rows)).toHaveLength(4)
    expect(secondPage.flatMap((group) => group.rows)).toHaveLength(4)
    expect(secondPage.flatMap((group) => group.rows)[0]?.symbol).not.toBe(
      firstPage.flatMap((group) => group.rows)[0]?.symbol,
    )
  })

  it("shows the capacity gauge and the Deposit row action in the table", () => {
    const group = LEND_ASSET_GROUPS[0]!
    const rows = group.rows.slice(0, 1).map((row) => ({ ...row, utilizationValue: 0.1968 }))

    render(<LendAssetSpokes groups={[{ ...group, rows }]} onDeposit={vi.fn()} />)

    expect(screen.getByRole("img", { name: "Capacity filled 20%" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Deposit" })).toBeInTheDocument()
    // Withdraw lives on the market detail page (desktop and phone share this table).
    expect(screen.queryByRole("button", { name: "Withdraw" })).not.toBeInTheDocument()
  })
})
