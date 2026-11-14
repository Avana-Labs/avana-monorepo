import { describe, expect, it } from "vitest"
import { calculateHealthFactorWad, currentDebtValueUsd6, formatFixed, parseFixed } from "@/app/lib/borrow-system/model"
import { applyBorrowAction } from "@/app/lib/borrow-system/model/actions"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { selectBorrowableAssets } from "@/app/lib/borrow-system/selectors"
import {
  selectBorrowSnapshot,
  selectPortfolioDebtRows,
  selectPortfolioSupplyRows,
} from "@/app/lib/borrow-system/dashboard-selectors"

describe("borrow dashboard selectors", () => {
  it("projects canonical borrow session state into dashboard row contexts", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const supplies = selectPortfolioSupplyRows(state, "demo-wallet")
    const debts = selectPortfolioDebtRows(state, "demo-wallet")
    const snapshot = selectBorrowSnapshot(state, "demo-wallet")

    expect(supplies).toHaveLength(3)
    expect(debts).toHaveLength(2)
    expect(snapshot.totalBorrowedUsd).toBe(2000)
    expect(snapshot.approvedUsd).toBeGreaterThan(0)
    expect(snapshot.spokeBreakdown).toHaveLength(2)
    expect(snapshot.spokeBreakdown.reduce((sum, row) => sum + row.totalBorrowedUsd, 0)).toBe(snapshot.totalBorrowedUsd)
    expect(supplies.find((row) => row.pool.id === "uni-v3-bluechip-wbtc-weth")?.borrowedUsd).toBe(0)
    expect(supplies.find((row) => row.pool.id === "uni-v3-bluechip-weth-usdc")?.borrowedUsd).toBe(1200)
  })

  it("carries each debt position's real debt-asset symbol, not a hardcoded USDC", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const debts = selectPortfolioDebtRows(state, "demo-wallet")

    // Every row exposes the symbol the repay flow resolves from state.assets.
    for (const row of debts) {
      const position = state.accounts["demo-wallet"]!.debtPositions.find((entry) => entry.id === row.id)!
      expect(row.debtAssetSymbol).toBe(state.assets[position.assetId]?.symbol)
    }

    // The mock seeds a genuine USDT debt (usdc-usdt spoke) alongside a USDC debt.
    const symbols = debts.map((row) => row.debtAssetSymbol)
    expect(symbols).toContain("USDT")
    expect(symbols).toContain("USDC")
  })

  it("single-sources debt-row borrow APR to the current market rate shown on the action page", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const debts = selectPortfolioDebtRows(state, "demo-wallet")

    expect(debts.length).toBeGreaterThan(0)

    for (const row of debts) {
      const position = state.accounts["demo-wallet"]!.debtPositions.find((entry) => entry.id === row.id)!
      const marketAssets = selectBorrowableAssets(state, "demo-wallet", position.marketId)
      const marketAsset = marketAssets.find((asset) => asset.id === position.assetId)!
      // Dashboard debt APR must equal the borrowable-asset (action page) APR for the same asset/market.
      expect(row.borrowApr).toBeCloseTo(marketAsset.borrowApr, 6)
      // Seeded positions store only the base rate; the displayed APR includes the risk premium.
      expect(row.borrowApr).toBeGreaterThanOrEqual(Number.parseFloat(formatFixed(position.borrowRateWad, 18)) * 100)
    }
  })

  it("does not drop debt in an unpledged market, and never shows a false ∞ health factor while owing", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    // Simulate hydrated data where a debt's market is NOT one of the wallet's
    // pledged pools (the debt is backed by spoke-shared collateral pledged in a
    // different market). "uni-v3-bluechip-weth-usdt" is a real bluechip market the
    // demo wallet has not pledged. The old selector keyed debt rows on pledged
    // pools only, so this debt vanished from the table while "Total Borrowed"
    // still counted it, and per-row HF read ∞ ("safe").
    const account = state.accounts["demo-wallet"]!
    const bluechipDebt = account.debtPositions.find((position) => position.spokeId === "uni-v3-bluechip")!
    bluechipDebt.marketId = "uni-v3-bluechip-weth-usdt"

    const debts = selectPortfolioDebtRows(state, "demo-wallet")
    const snapshot = selectBorrowSnapshot(state, "demo-wallet")

    // The debt in the unpledged market is present (not silently dropped).
    const orphan = debts.find((row) => row.pool.id === "uni-v3-bluechip-weth-usdt")
    expect(orphan).toBeDefined()

    // Its debt is counted, and no debt row falsely reads ∞ ("safe") while owing.
    expect(orphan!.borrowedUsd).toBeGreaterThan(0)
    expect(snapshot.totalBorrowedUsd).toBeGreaterThan(0)
    for (const row of debts) {
      expect(row.healthFactor).not.toBe(Number.POSITIVE_INFINITY)
      expect(Number.isFinite(row.healthFactor ?? 0)).toBe(true)
    }

    // Every outstanding debt position is represented — rows never hide debt the total counts.
    const outstanding = account.debtPositions.filter((position) => currentDebtValueUsd6(position) > 0n)
    expect(debts).toHaveLength(outstanding.length)
  })

  it("reflects shared-session borrow activity in debt and collateral rows", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const next = applyBorrowAction(state, {
      type: "borrow",
      walletId: "demo-wallet",
      marketId: "uni-v3-bluechip-weth-usdc",
      assetId: "uni-v3-bluechip:usdc",
      amountUsd6: parseFixed("300", 6),
    })

    const supplies = selectPortfolioSupplyRows(next, "demo-wallet")
    const debts = selectPortfolioDebtRows(next, "demo-wallet")

    expect(supplies.find((row) => row.pool.id === "uni-v3-bluechip-weth-usdc")?.borrowedUsd).toBeGreaterThan(1200)
    expect(debts.find((row) => row.pool.id === "uni-v3-bluechip-weth-usdc")?.borrowedUsd).toBeGreaterThan(1200)
    expect(debts.some((row) => row.id.includes("uni-v3-bluechip:usdc"))).toBe(true)
  })

  it("keeps wallet-wide totals while exposing the spoke that changed", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const next = applyBorrowAction(state, {
      type: "borrow",
      walletId: "demo-wallet",
      marketId: "uni-v3-bluechip-weth-usdc",
      assetId: "uni-v3-bluechip:usdc",
      amountUsd6: parseFixed("150", 6),
    })

    const snapshot = selectBorrowSnapshot(next, "demo-wallet")
    const bluechip = snapshot.spokeBreakdown.find((row) => row.spokeId === "uni-v3-bluechip")
    const stable = snapshot.spokeBreakdown.find((row) => row.spokeId === "uni-v3-stable")

    expect(snapshot.totalBorrowedUsd).toBe(2150)
    expect(bluechip?.totalBorrowedUsd).toBe(1350)
    expect(stable?.totalBorrowedUsd).toBe(800)
  })

  it("scopes each collateral row's borrow power to its OWN pool, not the whole spoke", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const supplies = selectPortfolioSupplyRows(state, "demo-wallet")

    // Two collateral positions in the SAME bluechip spoke but with different
    // collateral: eth-usdc ($4,200) and wbtc-eth ($2,100). The buggy selector read
    // the whole-spoke available credit, so both rows reported the SAME figure.
    const ethUsdc = supplies.find((row) => row.pool.id === "uni-v3-bluechip-weth-usdc")!
    const wbtcEth = supplies.find((row) => row.pool.id === "uni-v3-bluechip-wbtc-weth")!

    expect(ethUsdc).toBeDefined()
    expect(wbtcEth).toBeDefined()
    // Same spoke, different collateral => DIFFERENT per-position borrow power.
    expect(ethUsdc.pool.collateralUsd).not.toBe(wbtcEth.pool.collateralUsd)
    expect(ethUsdc.remainingBorrowPowerUsd).not.toBe(wbtcEth.remainingBorrowPowerUsd)

    // Every row's borrow power equals its own collateral × maxLtv minus its own
    // debt, and can NEVER exceed that position's own collateral value.
    for (const row of supplies) {
      const expected = Math.max(0, row.pool.collateralUsd * (Math.min(row.pool.maxLtv, 100) / 100) - row.borrowedUsd)
      expect(row.remainingBorrowPowerUsd).toBeCloseTo(expected, 6)
      expect(row.remainingBorrowPowerUsd).toBeGreaterThanOrEqual(0)
      expect(row.remainingBorrowPowerUsd).toBeLessThanOrEqual(row.pool.collateralUsd)
    }
  })

  it("uses spoke-level engine health factors for portfolio rows", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const supplies = selectPortfolioSupplyRows(state, "demo-wallet")
    const debts = selectPortfolioDebtRows(state, "demo-wallet")
    const bluechipMarketId = "uni-v3-bluechip-weth-usdc"
    const expectedHealthFactor = Number.parseFloat(
      formatFixed(calculateHealthFactorWad(state, "demo-wallet", "uni-v3-bluechip")!, 18),
    )

    expect(supplies.find((row) => row.pool.id === bluechipMarketId)?.healthFactor).toBeCloseTo(expectedHealthFactor, 2)
    expect(debts.find((row) => row.pool.id === bluechipMarketId)?.healthFactor).toBeCloseTo(expectedHealthFactor, 2)
  })
})
