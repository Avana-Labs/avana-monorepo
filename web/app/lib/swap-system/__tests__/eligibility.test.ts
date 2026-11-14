import { describe, expect, it } from "vitest"
import {
  NATIVE_GAS_RESERVE_ETH,
  getMaxSwapInputAmount,
  getSwapEligibility,
  validateSwapInputAmount,
  type SwapContext,
  type UserAssetBalance,
} from "@/app/lib/swap-system"

const context: SwapContext = {
  originProduct: "wallet",
  chainId: 1,
  outputAssetId: "usdc",
}

function balance(partial: Partial<UserAssetBalance> & Pick<UserAssetBalance, "assetId" | "amount">): UserAssetBalance {
  return {
    id: `${partial.assetId}-${partial.sourceType ?? "wallet"}`,
    walletId: "demo-wallet",
    sourceType: "wallet",
    ...partial,
  }
}

describe("swap eligibility", () => {
  it("allows supported wallet-held assets", () => {
    expect(getSwapEligibility(balance({ assetId: "eth", amount: 1 }), context)).toEqual({
      eligible: true,
      availableAmount: 1,
    })
  })

  it("rejects lend-deposited balances", () => {
    expect(
      getSwapEligibility(balance({ assetId: "usdc", amount: 100, sourceType: "lend_deposited" }), {
        ...context,
        outputAssetId: "eth",
      }),
    ).toEqual({ eligible: false, availableAmount: 0, reason: "ineligible_deposited" })
  })

  it("rejects LP tokens from wallet, pledged borrow collateral, and unpledged borrow collateral", () => {
    for (const sourceType of ["wallet", "borrow_collateral_pledged", "borrow_collateral_unpledged"] as const) {
      expect(getSwapEligibility(balance({ assetId: "eth-usdc-lp", amount: 3, sourceType }), context)).toEqual({
        eligible: false,
        availableAmount: 0,
        reason: "ineligible_lp_token",
      })
    }
  })

  it("rejects active multiply balances while keeping separate wallet balances eligible", () => {
    const balances = [
      balance({ assetId: "eth", amount: 3, sourceType: "multiply_active" }),
      balance({ assetId: "eth", amount: 5, sourceType: "wallet" }),
    ]

    expect(getSwapEligibility(balances[0]!, context)).toEqual({
      eligible: false,
      availableAmount: 0,
      reason: "ineligible_active_loop",
    })
    expect(getSwapEligibility(balances[1]!, context).eligible).toBe(true)
  })

  it("rejects protocol-locked and unsupported assets", () => {
    expect(getSwapEligibility(balance({ assetId: "gho", amount: 10, sourceType: "protocol_locked" }), context)).toEqual(
      {
        eligible: false,
        availableAmount: 0,
        reason: "ineligible_protocol_locked",
      },
    )
    expect(getSwapEligibility(balance({ assetId: "not-real", amount: 10 }), context)).toEqual({
      eligible: false,
      availableAmount: 0,
      reason: "unsupported_asset",
    })
  })

  it("rejects same-asset and zero-balance inputs", () => {
    expect(getSwapEligibility(balance({ assetId: "usdc", amount: 10 }), context)).toEqual({
      eligible: false,
      availableAmount: 10,
      reason: "same_asset",
    })
    expect(getSwapEligibility(balance({ assetId: "eth", amount: 0 }), context)).toEqual({
      eligible: false,
      availableAmount: 0,
      reason: "insufficient_balance",
    })
  })
})

describe("swap amount validation", () => {
  it.each(["", "0", "-1", "abc", "1e3"])("rejects invalid amount input %s", (amountText) => {
    expect(
      validateSwapInputAmount({ amountText, balance: balance({ assetId: "eth", amount: 1 }), context }),
    ).toMatchObject({
      valid: false,
      reason: "invalid_amount",
    })
  })

  it("caps Max to the native token balance minus gas reserve", () => {
    const input = balance({ assetId: "eth", amount: 1 })

    expect(getMaxSwapInputAmount(input, context)).toBe(1 - NATIVE_GAS_RESERVE_ETH)
    expect(validateSwapInputAmount({ amountText: "0.999", balance: input, context })).toMatchObject({
      valid: false,
      reason: "insufficient_native_gas",
    })
  })

  it("uses only eligible wallet balance for Max", () => {
    expect(getMaxSwapInputAmount(balance({ assetId: "eth", amount: 3, sourceType: "multiply_active" }), context)).toBe(
      0,
    )
  })

  it("rejects amounts below provider minimum, above maximum, and above eligible balance", () => {
    expect(
      validateSwapInputAmount({
        amountText: "0.1",
        balance: balance({ assetId: "usdc", amount: 100 }),
        context: { ...context, outputAssetId: "eth" },
      }),
    ).toMatchObject({
      valid: false,
      reason: "below_minimum",
    })
    expect(
      validateSwapInputAmount({
        amountText: "1000001",
        balance: balance({ assetId: "usdc", amount: 2_000_000 }),
        context: { ...context, outputAssetId: "eth" },
      }),
    ).toMatchObject({
      valid: false,
      reason: "above_maximum",
    })
    expect(
      validateSwapInputAmount({
        amountText: "101",
        balance: balance({ assetId: "usdc", amount: 100 }),
        context: { ...context, outputAssetId: "eth" },
      }),
    ).toMatchObject({
      valid: false,
      reason: "insufficient_balance",
    })
  })
})
