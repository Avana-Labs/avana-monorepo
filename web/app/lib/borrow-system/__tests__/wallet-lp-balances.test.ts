import { describe, expect, it } from "vitest"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { getWalletLpBalanceUsd } from "@/app/lib/borrow-system/wallet-lp-balances"

describe("getWalletLpBalanceUsd", () => {
  it("reads wallet LP balances from borrow session state", () => {
    const state = buildMockBorrowSystemState("demo-wallet")

    expect(getWalletLpBalanceUsd(state, "demo-wallet", "uni-v3-bluechip-weth-usdc")).toBe(8_400)
    expect(getWalletLpBalanceUsd(state, "demo-wallet", "uni-v3-bluechip-wbtc-weth")).toBe(4_200)
    expect(getWalletLpBalanceUsd(state, "demo-wallet", "uni-v3-stable-usdc-usdt")).toBe(16_200)
  })

  it("returns zero when the wallet has no LP balance for a market", () => {
    const state = buildMockBorrowSystemState("demo-wallet")

    // A market id that is not in the catalog has no seeded balance.
    expect(getWalletLpBalanceUsd(state, "demo-wallet", "nonexistent-market-xyz")).toBe(0)
    expect(getWalletLpBalanceUsd(state, "other-wallet", "uni-v3-bluechip-wbtc-weth")).toBe(0)
  })
})
