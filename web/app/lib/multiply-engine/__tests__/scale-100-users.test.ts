import { describe, expect, it } from "vitest"
import {
  applyMultiplyActions,
  assertMultiplySystemInvariants,
  calculateMultiplyHealthFactor,
} from "@/app/lib/multiply-engine"
import { makeStressMultiplyActions, makeStressMultiplySystemState } from "./stress-fixtures"

describe("multiply system 100-user scale", () => {
  it(
    "settles 100 heterogeneous wallet sessions while keeping reads and invariants consistent",
    { timeout: 30_000 },
    () => {
      const initialState = makeStressMultiplySystemState(100)
      const actions = makeStressMultiplyActions(initialState)
      const nextState = applyMultiplyActions(initialState, actions)

      assertMultiplySystemInvariants(nextState)
      expect(Object.keys(initialState.markets)).toHaveLength(20)
      expect(nextState.transactions.length).toBeGreaterThan(0)

      const sampledWalletIds = [
        "wallet-multiply-stress-0",
        "wallet-multiply-stress-7",
        "wallet-multiply-stress-25",
        "wallet-multiply-stress-50",
        "wallet-multiply-stress-99",
      ]

      for (const walletId of sampledWalletIds) {
        const positions = Object.values(nextState.positions).filter((position) => position.walletId === walletId)
        for (const position of positions) {
          expect(Number.isFinite(position.collateralValueUsd)).toBe(true)
          expect(Number.isFinite(position.debtValueUsd)).toBe(true)
          expect(position.multiplier).toBeGreaterThanOrEqual(1)
          expect(position.healthFactor === "infinity" || position.healthFactor > 0).toBe(true)
        }
      }

      const deleveraged = nextState.transactions.filter((transaction) => transaction.kind === "deleverage")
      expect(deleveraged.length).toBeGreaterThan(0)

      for (const transaction of deleveraged) {
        expect(transaction.multiplierAfter).toBeLessThan(transaction.multiplierBefore)
      }

      const whale = Object.values(nextState.positions).find(
        (position) => position.walletId === "wallet-multiply-stress-0",
      )
      const regular = Object.values(nextState.positions).find(
        (position) => position.walletId === "wallet-multiply-stress-7",
      )
      if (whale && regular) {
        expect(whale.collateralValueUsd).toBeGreaterThan(regular.collateralValueUsd)
      }

      const ethMarket = nextState.markets["eth-usdt"]
      expect(ethMarket?.rank).toBe(10)
      expect(ethMarket?.ui.featured).toBe(true)

      const health = calculateMultiplyHealthFactor(7000, 3000, ethMarket!.risk.liquidationThreshold)
      expect(health).toBeGreaterThan(1)
    },
  )
})
