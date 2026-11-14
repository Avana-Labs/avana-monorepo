import { describe, expect, it } from "vitest"
import { buildLendActivityHistory, buildPortfolioLendData } from "@/app/lib/lend-system/read-model"
import { buildMockLendSystemStateWithSeedPosition } from "@/app/lib/lend-system/mock"
import type { LendTransactionHistoryItem } from "@/app/lib/lend-system/contracts"

describe("buildPortfolioLendData", () => {
  it("maps lend activity into usd amounts for dashboard history", () => {
    const state = buildMockLendSystemStateWithSeedPosition("wallet-1")
    const market = state.markets.eth!
    const history: LendTransactionHistoryItem[] = [
      {
        id: "tx-1",
        intentId: "intent-1",
        walletId: "wallet-1",
        marketId: market.marketId,
        positionId: "wallet-1:eth",
        kind: "deposit",
        status: "success",
        asset: market.asset.symbol,
        amount: 2,
        simulated: true,
        timestamp: state.now,
        hash: "0xdeposit",
      },
      {
        id: "tx-2",
        intentId: "intent-2",
        walletId: "wallet-1",
        marketId: market.marketId,
        positionId: "wallet-1:eth",
        kind: "withdraw",
        status: "success",
        asset: market.asset.symbol,
        amount: 0.5,
        simulated: true,
        timestamp: state.now + 60_000,
        hash: "0xwithdraw",
      },
    ]

    const portfolio = buildPortfolioLendData("wallet-1", state, history)

    expect(portfolio.history).toHaveLength(2)
    expect(portfolio.history[0]?.amountUsd).toBeCloseTo(2 * market.assetPriceUsd, 6)
    expect(portfolio.history[1]?.amountUsd).toBeCloseTo(0.5 * market.assetPriceUsd, 6)
  })

  it("prices deposit activity only when state is supplied (dashboard must pass state)", () => {
    const state = buildMockLendSystemStateWithSeedPosition("wallet-1")
    const market = state.markets.eth!
    const history: LendTransactionHistoryItem[] = [
      {
        id: "tx-1",
        intentId: "intent-1",
        walletId: "wallet-1",
        marketId: market.marketId,
        positionId: "wallet-1:eth",
        kind: "deposit",
        status: "success",
        asset: market.asset.symbol,
        amount: 2,
        simulated: true,
        timestamp: state.now,
        hash: "0xdeposit",
      },
    ]

    // Without state the value collapses to $0 (the dashboard regression).
    expect(buildLendActivityHistory("wallet-1", history)[0]?.amountUsd).toBe(0)
    // With state the deposit resolves to its real USD value.
    expect(buildLendActivityHistory("wallet-1", history, state)[0]?.amountUsd).toBeCloseTo(2 * market.assetPriceUsd, 6)
  })

  it("labels a lend deposit as Supply (not Open) and a withdraw as Withdraw", () => {
    const state = buildMockLendSystemStateWithSeedPosition("wallet-1")
    const market = state.markets.eth!
    const history: LendTransactionHistoryItem[] = [
      {
        id: "tx-1",
        intentId: "intent-1",
        walletId: "wallet-1",
        marketId: market.marketId,
        positionId: "wallet-1:eth",
        kind: "deposit",
        status: "success",
        asset: market.asset.symbol,
        amount: 2,
        simulated: true,
        timestamp: state.now,
        hash: "0xdeposit",
      },
      {
        id: "tx-2",
        intentId: "intent-2",
        walletId: "wallet-1",
        marketId: market.marketId,
        positionId: "wallet-1:eth",
        kind: "withdraw",
        status: "success",
        asset: market.asset.symbol,
        amount: 0.5,
        simulated: true,
        timestamp: state.now + 60_000,
        hash: "0xwithdraw",
      },
    ]

    const rows = buildLendActivityHistory("wallet-1", history, state)

    // A deposit is a supply, not "open"; a withdraw stays a withdraw.
    expect(rows.find((row) => row.id === "tx-1")?.kind).toBe("supply")
    expect(rows.find((row) => row.id === "tx-2")?.kind).toBe("withdraw")
  })

  it("de-fuzzes the reconstructed token amount in the activity label (no false precision)", () => {
    const state = buildMockLendSystemStateWithSeedPosition("wallet-1")
    const market = state.markets.eth!
    // A 100-unit supply reconstructs from USD to 100.0035; the label must read "100 <asset>".
    const history: LendTransactionHistoryItem[] = [
      {
        id: "tx-1",
        intentId: "intent-1",
        walletId: "wallet-1",
        marketId: market.marketId,
        positionId: "wallet-1:eth",
        kind: "deposit",
        status: "success",
        asset: market.asset.symbol,
        amount: 100.0035,
        simulated: true,
        timestamp: state.now,
        hash: "0xdeposit",
      },
    ]

    const [row] = buildLendActivityHistory("wallet-1", history, state)
    expect(row?.secondaryLabel).toBe(`100 ${market.asset.symbol}`)
  })
})
