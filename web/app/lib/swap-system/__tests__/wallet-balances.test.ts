import { describe, expect, it } from "vitest"
import {
  buildDashboardWalletBalanceRows,
  getUserSwapBalances,
  selectDashboardWalletValueRows,
  type UserAssetBalance,
} from "@/app/lib/swap-system"

const balances: UserAssetBalance[] = [
  { id: "wallet-eth", walletId: "w1", assetId: "eth", amount: 2, sourceType: "wallet" },
  { id: "lend-usdc", walletId: "w1", assetId: "usdc", amount: 1000, sourceType: "lend_deposited" },
  { id: "wallet-lp", walletId: "w1", assetId: "eth-usdc-lp", amount: 4, sourceType: "wallet" },
  { id: "active-eth", walletId: "w1", assetId: "eth", amount: 3, sourceType: "multiply_active" },
  { id: "wallet-link", walletId: "w2", assetId: "link", amount: 9, sourceType: "wallet" },
]

describe("swap wallet balance classification", () => {
  it("scopes raw balances to the selected wallet", () => {
    expect(getUserSwapBalances("w1", balances).map((row) => row.id)).toEqual([
      "wallet-eth",
      "lend-usdc",
      "wallet-lp",
      "active-eth",
    ])
  })

  it("names an off-catalog token stored as its ticker by its full name", () => {
    const [op] = buildDashboardWalletBalanceRows({
      walletId: "w1",
      balances: [
        {
          id: "wallet-op",
          walletId: "w1",
          assetId: "op",
          symbol: "OP",
          name: "OP",
          amount: 100.27,
          valueUsd: 13.21,
          sourceType: "wallet",
        },
      ],
    })
    expect(op).toMatchObject({ symbol: "OP", name: "Optimism" })
  })

  it("shows LP wallet balances but marks them unswappable", () => {
    const lp = buildDashboardWalletBalanceRows({ walletId: "w1", balances }).find((row) => row.id === "wallet-lp")

    expect(lp).toMatchObject({
      isLpToken: true,
      swappable: false,
      restrictionReason: "ineligible_lp_token",
    })
  })

  it("resolves Multiply collateral metadata instead of exposing an unsupported-asset label", () => {
    const [row] = buildDashboardWalletBalanceRows({
      walletId: "w1",
      balances: [
        { id: "multiply-wsteth", walletId: "w1", assetId: "wsteth", amount: 2, sourceType: "multiply_available" },
      ],
    })

    expect(row).toMatchObject({ symbol: "WSTETH", name: "Wrapped stETH", isLpToken: false })
    expect(row?.name).not.toBe("Unsupported asset")
  })

  it("merges duplicate product rows and drops empty rows for dashboard display", () => {
    const rows = buildDashboardWalletBalanceRows({
      walletId: "w1",
      balances: [
        {
          id: "available-lp",
          walletId: "w1",
          assetId: "eth-usdc-lp",
          amount: 5.6,
          valueUsd: 700,
          sourceType: "borrow_collateral_unpledged",
        },
        {
          id: "zero-lp",
          walletId: "w1",
          assetId: "eth-usdc-lp",
          amount: 0,
          valueUsd: 0,
          sourceType: "borrow_collateral_unpledged",
        },
        {
          id: "more-lp",
          walletId: "w1",
          assetId: "eth-usdc-lp",
          amount: 0.8,
          valueUsd: 100,
          sourceType: "borrow_collateral_unpledged",
        },
      ],
    })

    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({
      assetId: "eth-usdc-lp",
      valueUsd: 800,
    })
    expect(rows[0]?.amount).toBeCloseTo(6.4, 6)
  })

  it("does not merge liquid and product-scoped token rows", () => {
    const rows = buildDashboardWalletBalanceRows({
      walletId: "w1",
      balances: [
        { id: "liquid-usdc", walletId: "w1", assetId: "usdc", amount: 840, valueUsd: 840, sourceType: "wallet" },
        { id: "lend-usdc", walletId: "w1", assetId: "usdc", amount: 25, valueUsd: 25, sourceType: "lend_deposited" },
      ],
    })

    expect(rows.map((row) => row.id).sort()).toEqual(["lend-usdc", "liquid-usdc"])
  })

  it("keeps Wallet Balance aligned with returned wallet-accessible product rows", () => {
    const rows = buildDashboardWalletBalanceRows({
      walletId: "w1",
      balances: [
        {
          id: "liquid-usdc",
          walletId: "w1",
          assetId: "usdc",
          amount: 109_812,
          valueUsd: 109_812,
          sourceType: "wallet",
        },
        {
          id: "returned-pool-a",
          walletId: "w1",
          assetId: "aura-weth-lp",
          amount: 1,
          valueUsd: 43_750,
          sourceType: "borrow_collateral_unpledged",
        },
        {
          id: "returned-pool-b",
          walletId: "w1",
          assetId: "wbtc-eth-lp",
          amount: 1,
          valueUsd: 43_750,
          sourceType: "borrow_collateral_unpledged",
        },
      ],
    })

    expect(selectDashboardWalletValueRows(rows).reduce((sum, row) => sum + row.valueUsd, 0)).toBe(197_312)
  })
})
