import { describe, expect, it } from "vitest"
import { RAY, parseFixed } from "@/app/lib/credit-engine"
import {
  calculateCollateralValueUsd6,
  collateralInterestEarnedUsd6,
  currentCollateralValueUsd6,
  currentDebtValueUsd6,
  debtInterestOwedUsd6,
  totalCollateralValueUsd6,
  totalDebtValueUsd6,
  totalInterestEarnedUsd6,
  totalInterestOwedUsd6,
} from "@/app/lib/credit-engine/valuation"
import { makeExampleBorrowSystemState } from "./fixtures"

describe("borrow valuation helpers", () => {
  it("values collateral from shares and lp prices", () => {
    const state = makeExampleBorrowSystemState()
    const market = state.markets["uni-v3-bluechip-weth-usdc"]!
    const position = state.accounts["wallet-1"]!.collateralPositions[0]!

    expect(currentCollateralValueUsd6(position, market)).toBe(parseFixed("15223.065", 6))
  })

  it("tracks accrued collateral yield through the supply index", () => {
    const state = makeExampleBorrowSystemState()
    const market = state.markets["uni-v3-bluechip-weth-usdc"]!
    const position = state.accounts["wallet-1"]!.collateralPositions[0]!

    market.snapshot.supplyIndexRay = RAY + parseFixed("0.05", 18) * (RAY / parseFixed("1", 18))

    expect(collateralInterestEarnedUsd6(position, market)).toBe(parseFixed("761.15325", 6))
  })

  it("values debt and interest from debt shares plus debt index", () => {
    const state = makeExampleBorrowSystemState()
    const debt = state.accounts["wallet-1"]!.debtPositions[0]!

    debt.debtIndexRay = RAY + parseFixed("0.08", 18) * (RAY / parseFixed("1", 18))

    expect(currentDebtValueUsd6(debt)).toBe(parseFixed("6696", 6))
    expect(debtInterestOwedUsd6(debt)).toBe(parseFixed("496", 6))
  })

  it("aggregates per-account collateral and debt totals", () => {
    const state = makeExampleBorrowSystemState()
    const account = state.accounts["wallet-1"]!

    expect(totalCollateralValueUsd6(account, state.markets)).toBe(parseFixed("20399.225", 6))
    expect(totalDebtValueUsd6(account)).toBe(parseFixed("6200", 6))
    expect(totalInterestEarnedUsd6(account, state.markets)).toBe(0n)
    expect(totalInterestOwedUsd6(account)).toBe(0n)
  })

  it("calculates collateral value for a wallet using all enabled LP positions", () => {
    const state = makeExampleBorrowSystemState()

    expect(calculateCollateralValueUsd6(state, "wallet-1")).toBe(parseFixed("20399.225", 6))
  })

  it("returns zero collateral value when the wallet has no enabled collateral", () => {
    const state = makeExampleBorrowSystemState()
    state.accounts["wallet-1"]!.collateralPositions = []

    expect(calculateCollateralValueUsd6(state, "wallet-1")).toBe(0n)
  })

  it("handles missing or invalid collateral prices safely", () => {
    const state = makeExampleBorrowSystemState()
    state.markets["uni-v3-bluechip-weth-usdc"]!.snapshot.lpTokenPriceUsd6 = 0n

    expect(calculateCollateralValueUsd6(state, "wallet-1")).toBe(parseFixed("5176.16", 6))
  })

  it("values multiple LP collateral positions independently and sums wallet total", () => {
    const state = makeExampleBorrowSystemState()
    const account = state.accounts["wallet-1"]!
    const uniPosition = account.collateralPositions.find(
      (position) => position.marketId === "uni-v3-bluechip-weth-usdc",
    )!
    const curvePosition = account.collateralPositions.find((position) => position.marketId === "curve-eth-usdt")!
    const uniMarket = state.markets["uni-v3-bluechip-weth-usdc"]!
    const curveMarket = state.markets["curve-eth-usdt"]!

    const expected =
      currentCollateralValueUsd6(uniPosition, uniMarket) + currentCollateralValueUsd6(curvePosition, curveMarket)

    expect(calculateCollateralValueUsd6(state, "wallet-1")).toBe(expected)
    expect(expected).toBe(parseFixed("20399.225", 6))
  })

  it("ignores disabled collateral positions when calculating wallet collateral value", () => {
    const state = makeExampleBorrowSystemState()
    state.accounts["wallet-1"]!.collateralPositions = state.accounts["wallet-1"]!.collateralPositions.map(
      (position, index) => ({
        ...position,
        collateralEnabled: index === 0,
      }),
    )

    const enabledPosition = state.accounts["wallet-1"]!.collateralPositions[0]!
    const enabledMarket = state.markets[enabledPosition.marketId]!

    expect(calculateCollateralValueUsd6(state, "wallet-1")).toBe(
      currentCollateralValueUsd6(enabledPosition, enabledMarket),
    )
  })

  it("returns zero collateral value when all LP prices are zero", () => {
    const state = makeExampleBorrowSystemState()
    for (const market of Object.values(state.markets)) {
      market.snapshot.lpTokenPriceUsd6 = 0n
    }

    expect(calculateCollateralValueUsd6(state, "wallet-1")).toBe(0n)
  })

  it("handles missing market records without throwing", () => {
    const state = makeExampleBorrowSystemState()
    state.accounts["wallet-1"]!.collateralPositions.push({
      id: "wallet-1:missing-market",
      marketId: "missing-market",
      collateralShares: parseFixed("10", 18),
      principalTokenAmount: parseFixed("10", 18),
      collateralEnabled: true,
    })

    expect(calculateCollateralValueUsd6(state, "wallet-1")).toBe(parseFixed("20399.225", 6))
  })
})
