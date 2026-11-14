import { describe, expect, it } from "vitest"
import { applyLendActions, assertLendSystemInvariants } from "@/app/lib/lend-engine"
import { makeStressLendActions, makeStressLendSystemState } from "./stress-fixtures"

describe("lend system 100-user scale", () => {
  it(
    "settles 100 heterogeneous wallet sessions while keeping reads and invariants consistent",
    { timeout: 30_000 },
    () => {
      const initialState = makeStressLendSystemState(100)
      const actions = makeStressLendActions(initialState)
      const nextState = applyLendActions(initialState, actions)

      assertLendSystemInvariants(nextState)
      expect(Object.keys(initialState.markets).length).toBeGreaterThan(10)
      expect(nextState.transactions.length).toBeGreaterThan(0)

      const sampledWalletIds = [
        "wallet-lend-stress-0",
        "wallet-lend-stress-7",
        "wallet-lend-stress-25",
        "wallet-lend-stress-50",
        "wallet-lend-stress-99",
      ]

      for (const walletId of sampledWalletIds) {
        const positions = Object.values(nextState.positions).filter((position) => position.walletId === walletId)
        for (const position of positions) {
          expect(Number.isFinite(position.currentSuppliedAmount)).toBe(true)
          expect(Number.isFinite(position.suppliedValueUsd)).toBe(true)
          expect(position.currentSuppliedAmount).toBeGreaterThanOrEqual(0)
        }
      }

      const withdrawals = nextState.transactions.filter((transaction) => transaction.kind === "withdraw")
      expect(withdrawals.length).toBeGreaterThan(0)

      const whale = Object.values(initialState.positions).find(
        (position) => position.walletId === "wallet-lend-stress-0",
      )
      const regular = Object.values(initialState.positions).find(
        (position) => position.walletId === "wallet-lend-stress-7",
      )
      if (whale && regular) {
        expect(whale.suppliedValueUsd).toBeGreaterThan(regular.suppliedValueUsd)
      }
    },
  )
})
