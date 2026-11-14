import { describe, expect, it } from "vitest"
import { aggregateNetValueUsd } from "@/app/dashboard/use-dashboard-portfolio-summary"
import type { UserAssetBalance } from "@/app/lib/swap-system"

/**
 * Regression cover for product-balance rows that store a USD figure in the token-quantity
 * `amount` field. Repricing those as `amount × livePrice` multiplied a position by the token
 * price. Values below are the ones observed on the live deployment: depositing exactly 1 AAVE
 * (oracle $120.18240206615957) wrote `amount: 120.18240206615957` and pushed dashboard Net
 * Value from $1,032,469 to $1,046,589.
 */
const AAVE = 120.18240206615957
const priceFor = (symbol: string): number | undefined =>
  ({ AAVE, ETH: 3000, USDC: 1, WBTC: 65000 })[symbol.trim().toUpperCase()]

function row(partial: Partial<UserAssetBalance> & { assetId: string; amount: number }): UserAssetBalance {
  return { id: partial.assetId, walletId: "w", sourceType: "wallet", ...partial }
}

describe("aggregateNetValueUsd — token-vs-USD amount units", () => {
  it("does not reprice a lend row whose amount holds USD (live 1 AAVE deposit)", () => {
    const rows = [row({ assetId: "aave", amount: AAVE, valueUsd: AAVE, sourceType: "lend_deposited" })]
    expect(aggregateNetValueUsd(rows, priceFor)).toBeCloseTo(AAVE, 6)
  })

  it("does not reprice a multiply debt row whose amount holds USD", () => {
    const rows = [row({ assetId: "eth", amount: 30_000, valueUsd: -30_000, sourceType: "multiply_debt" })]
    expect(aggregateNetValueUsd(rows, priceFor)).toBeCloseTo(-30_000, 6)
  })

  it("does not reprice a borrow debt row whose amount holds USD", () => {
    const rows = [row({ assetId: "eth", amount: 2_000, valueUsd: -2_000, sourceType: "borrow_debt" })]
    expect(aggregateNetValueUsd(rows, priceFor)).toBeCloseTo(-2_000, 6)
  })

  it("still reprices a genuinely token-denominated row at the live price", () => {
    // Seeded ETH lend leg: 21.37 ETH stored against $37,500 → implied $1,754, live $3,000.
    // That is a real 1.71x price move (inside the trust band), so it must reprice.
    const rows = [row({ assetId: "eth", amount: 21.37237524045652, valueUsd: 37_500, sourceType: "lend_deposited" })]
    expect(aggregateNetValueUsd(rows, priceFor)).toBeCloseTo(21.37237524045652 * 3000, 6)
  })

  it("reprices a WBTC row whose amount is a real token quantity", () => {
    const rows = [row({ assetId: "wbtc", amount: 0.592347179217264, valueUsd: 37_500, sourceType: "lend_deposited" })]
    expect(aggregateNetValueUsd(rows, priceFor)).toBeCloseTo(0.592347179217264 * 65_000, 6)
  })

  it("does not double-count a lend available mirror of a liquid holding", () => {
    // A lend withdrawal credits BOTH walletLiquidBalances and the lend `available` bucket.
    // The wallet's real pre-existing rows: 13,349.72 liquid USDC alongside a 49.99 USDC
    // lend-available mirror left by an earlier withdrawal.
    const rows = [
      row({ assetId: "usdc", amount: 13_349.719728914286, valueUsd: 13_349.719728914286 }),
      row({ assetId: "usdc", amount: 49.985271085712895, valueUsd: 49.985271085712895, sourceType: "lend_available" }),
    ]
    expect(aggregateNetValueUsd(rows, priceFor)).toBeCloseTo(13_349.719728914286, 6)
  })

  it("still counts a lend available bucket with no matching liquid row", () => {
    const rows = [row({ assetId: "gho", amount: 3, valueUsd: 3, sourceType: "lend_available" })]
    expect(aggregateNetValueUsd(rows, priceFor)).toBeCloseTo(3, 6)
  })

  it("keeps multiply_available (separate equity budget) even beside a liquid row", () => {
    const rows = [
      row({ assetId: "wsteth", amount: 2, valueUsd: 7_000 }),
      row({ assetId: "wsteth", amount: 41_666.67, valueUsd: 41_666.67, sourceType: "multiply_available" }),
    ]
    // Liquid repriced (no WSTETH price here → stored $7,000) plus the untouched budget.
    expect(aggregateNetValueUsd(rows, priceFor)).toBeCloseTo(7_000 + 41_666.67, 6)
  })

  it("does not double a sub-$10 token row whose amount holds USD (LDO/CRV/ARB/EURC hole)", () => {
    // These tokens' live prices sit INSIDE the [0.1, 10] drift band, so a USD-in-amount row (implied
    // unit price 1.0) used to pass the band and reprice as amount × livePrice — a $1,000 LDO row read
    // $2,000. Their stored USD is canonical.
    const priceForAlt = (symbol: string): number | undefined =>
      ({ LDO: 2, CRV: 0.6, ARB: 0.16, EURC: 1.08 })[symbol.trim().toUpperCase()]
    const badRow = (assetId: string) => row({ assetId, amount: 1_000, valueUsd: 1_000, sourceType: "lend_deposited" })
    for (const assetId of ["ldo", "crv", "arb", "eurc"]) {
      expect(aggregateNetValueUsd([badRow(assetId)], priceForAlt)).toBeCloseTo(1_000, 6)
    }
  })

  it("still reprices a GENUINE sub-$10 token row (real tokens, not USD-in-amount)", () => {
    // 500 LDO stored at open price $2 (valueUsd 1,000, implied 2.0 — NOT the ≈1 USD signature), live
    // $2.20 → must reprice to 500 × 2.20.
    const priceForAlt = (symbol: string): number | undefined =>
      symbol.trim().toUpperCase() === "LDO" ? 2.2 : undefined
    const rows = [row({ assetId: "ldo", amount: 500, valueUsd: 1_000, sourceType: "lend_deposited" })]
    expect(aggregateNetValueUsd(rows, priceForAlt)).toBeCloseTo(500 * 2.2, 6)
  })

  it("keeps a lend deposit value-neutral end to end", () => {
    // $120.18 of AAVE moves wallet → lend. Net Value must not change.
    const before = [row({ assetId: "aave", amount: 119.04761904761905, valueUsd: 12_500 })]
    const after = [
      row({ assetId: "aave", amount: 118.04761904761905, valueUsd: 12_500 - AAVE }),
      row({ assetId: "aave", amount: AAVE, valueUsd: AAVE, sourceType: "lend_deposited" }),
    ]
    const drift = aggregateNetValueUsd(after, priceFor) - aggregateNetValueUsd(before, priceFor)
    expect(Math.abs(drift)).toBeLessThan(1)
  })
})
