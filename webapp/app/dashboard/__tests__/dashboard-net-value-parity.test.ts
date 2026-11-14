import { describe, expect, it } from "vitest"
import { aggregateNetValueUsd } from "@/app/dashboard/use-dashboard-portfolio-summary"
import {
  buildDashboardWalletBalanceRows,
  selectDashboardWalletValueRows,
  type UserAssetBalance,
} from "@/app/lib/swap-system"
import { sumWalletValueUsd } from "@/app/dashboard/dashboard-wallet-tab"

/**
 * Pins the reconciliation the hero Net Value rests on. The hero is `aggregateNetValueUsd(rows) +
 * netAccruedInterestUsd`, computed off the productBalances rows. This test decomposes that hero into
 * named buckets and checks it reconciles — crucially it exercises the parts the OLD test could not:
 *
 *  - the WALLET term is the real Wallet-tab builder (buildDashboardWalletBalanceRows →
 *    selectDashboardWalletValueRows → sumWalletValueUsd), not another call to the hero function, so a
 *    divergence between the two would fail here;
 *  - the liquid-MIRROR coupling (a `lend_available` row that mirrors a liquid holding is dropped by
 *    BOTH the wallet builder and the hero) is present, so the decomposition is not a trivial partition.
 *
 * The Lend/Borrow position tabs re-derive their nets from these same rows via session
 * hydration (not unit-testable here); their row basis is what this decomposition pins.
 */

const priceFor = (symbol: string): number | undefined => ({ ETH: 2000, USDC: 1, AAVE: 90 })[symbol.trim().toUpperCase()]

function row(partial: Partial<UserAssetBalance> & { assetId: string; amount: number }): UserAssetBalance {
  return { id: `${partial.assetId}:${partial.sourceType ?? "wallet"}`, walletId: "w", sourceType: "wallet", ...partial }
}

// A representative wallet spanning every productBalances bucket, debt and a liquid mirror included.
const WALLET: UserAssetBalance[] = [
  row({ assetId: "usdc", amount: 1000, valueUsd: 1000, sourceType: "wallet" }),
  row({ assetId: "eth", amount: 0.1, valueUsd: 193, sourceType: "wallet" }), // repriced live → 200
]
const LIQUID_MIRROR: UserAssetBalance[] = [
  // A lend withdrawal credits BOTH the liquid USDC above and this available bucket — same tokens.
  row({ assetId: "usdc", amount: 500, valueUsd: 500, sourceType: "lend_available" }),
]
const LEND: UserAssetBalance[] = [
  row({ assetId: "lend-usdc", amount: 500, valueUsd: 500, sourceType: "lend_deposited" }),
]
const BORROW: UserAssetBalance[] = [
  row({ assetId: "weth-usdc-pool", amount: 8, valueUsd: 800, sourceType: "borrow_collateral_pledged" }),
  row({ assetId: "usdc", amount: 300, valueUsd: -300, sourceType: "borrow_debt" }),
]
const ALL = [...WALLET, ...LIQUID_MIRROR, ...LEND, ...BORROW]

const walletTabNetUsd = (rows: UserAssetBalance[]) =>
  sumWalletValueUsd(
    selectDashboardWalletValueRows(buildDashboardWalletBalanceRows({ walletId: "w", balances: rows, priceFor })),
  )

describe("dashboard Net Value reconciliation", () => {
  it("the hero equals the real Wallet-tab builder plus each product's row-basis net", () => {
    const hero = aggregateNetValueUsd(ALL, priceFor)

    const walletNet = walletTabNetUsd(ALL) // real Wallet tab builder, over the SAME rows
    const lendNet = aggregateNetValueUsd(LEND, priceFor)
    const borrowNet = aggregateNetValueUsd(BORROW, priceFor)

    expect(hero).toBeCloseTo(walletNet + lendNet + borrowNet, 6)
  })

  it("drops the liquid mirror from BOTH the hero and the Wallet tab (not a trivial partition)", () => {
    // The mirror couples buckets: hero(all) is NOT hero(wallet)+hero(lend_available)+…; the mirror is
    // subtracted once. Wallet 1200 + lend 500 + borrow 500 = 2,200.
    expect(aggregateNetValueUsd(ALL, priceFor)).toBeCloseTo(2_200, 6)
    // The 500 mirror is counted nowhere: removing it changes neither the hero nor the wallet term.
    const withoutMirror = ALL.filter((r) => r.sourceType !== "lend_available")
    expect(aggregateNetValueUsd(withoutMirror, priceFor)).toBeCloseTo(aggregateNetValueUsd(ALL, priceFor), 6)
    expect(walletTabNetUsd(withoutMirror)).toBeCloseTo(walletTabNetUsd(ALL), 6)
  })

  it("prices the concrete decomposition: live ETH, LP stored basis, signed debt", () => {
    // wallet 1000 + (0.1×2000=200) = 1200; lend 500; borrow 800 − 300 = 500 → 2,200.
    expect(aggregateNetValueUsd(ALL, priceFor)).toBeCloseTo(2_200, 6)
  })
})
