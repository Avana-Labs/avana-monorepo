import { describe, expect, it } from "vitest"
import { makeExampleBorrowSystemState } from "@/app/lib/credit-engine/__tests__/fixtures"
import { makeExampleMultiplySystemState } from "@/app/lib/multiply-engine/__tests__/fixtures"
import { buildMultiplyPageData } from "@/app/lib/multiply-system/read-model"
import { SandboxMultiplyReadAdapter } from "@/app/lib/multiply-system/sandbox-read-adapter"
import { SandboxMultiplyTransactionAdapter } from "@/app/lib/multiply-system/sandbox-transaction-adapter"

describe("SandboxMultiplyReadAdapter", () => {
  it("loads 20 markets and wallet-specific positions", async () => {
    const state = makeExampleMultiplySystemState()
    const adapter = new SandboxMultiplyReadAdapter({ state })

    const markets = await adapter.readMarkets()
    expect(markets).toHaveLength(20)

    const portfolio = await adapter.readPortfolioMultiply("wallet-1")
    expect(portfolio.positions.length).toBeGreaterThan(0)

    const page = await adapter.readMultiplyPage("wallet-1")
    expect(page.lendRows).toHaveLength(20)
    expect(page.trendingSnapshots).toHaveLength(3)
  })

  it("exposes wallet risk snapshots from open positions", async () => {
    const state = makeExampleMultiplySystemState()
    const adapter = new SandboxMultiplyReadAdapter({ state })
    const snapshot = await adapter.readWalletSnapshot("wallet-1")
    expect(snapshot.riskSnapshots.length).toBeGreaterThan(0)
  })

  it("builds the multiply page list from live session state, not a static snapshot", () => {
    // The /multiply page now renders from the wallet's session state so market
    // availability stays consistent with the detail page and dashboard after the
    // wallet's own multiply/deleverage actions consume or return liquidity.
    const state = makeExampleMultiplySystemState()
    const [firstMarketId] = Object.keys(state.markets)
    const market = state.markets[firstMarketId!]!
    const originalLiquidityUsd = market.economics.availableLiquidityUsd
    const consumedLiquidityUsd = Math.round(originalLiquidityUsd / 2)
    market.economics.availableLiquidityUsd = consumedLiquidityUsd

    const livePage = buildMultiplyPageData("wallet-1", state)

    // The page read tracks the live market liquidity rather than a frozen value.
    expect(consumedLiquidityUsd).not.toBe(originalLiquidityUsd)
    expect(livePage.markets[0]?.volume).toBe(consumedLiquidityUsd)
  })
})

describe("SandboxMultiplyTransactionAdapter", () => {
  it("rejects a multiply intent backed by a stale or unavailable Convex price", async () => {
    let multiplyState = makeExampleMultiplySystemState()
    const adapter = new SandboxMultiplyTransactionAdapter({
      readState: () => multiplyState,
      writeState: (nextState) => {
        multiplyState = nextState
      },
    })
    const intent = adapter.createIntent({
      type: "multiply",
      walletId: "wallet-2",
      marketId: "eth-usdt",
      collateralAmount: 0.5,
      selectedMultiplier: 2,
      collateralPriceUsd: 2_000,
      collateralPriceStale: true,
    })

    const preview = await adapter.previewTransaction(intent)
    const result = await adapter.executeTransaction(intent)

    expect(preview.allowed).toBe(false)
    expect(preview.validationErrors.join(" ")).toContain("Collateral price is stale")
    expect(result.receipt.status).toBe("failed")
    expect(multiplyState.transactions).toHaveLength(0)
  })

  it("rejects multiply intents that would open below the liquidation threshold", async () => {
    let multiplyState = makeExampleMultiplySystemState()
    multiplyState = {
      ...multiplyState,
      markets: {
        ...multiplyState.markets,
        "eth-usdt": {
          ...multiplyState.markets["eth-usdt"]!,
          risk: {
            ...multiplyState.markets["eth-usdt"]!.risk,
            maxLtv: 0.95,
            publicMaxMultiplier: 10,
            hardMaxMultiplier: 10,
          },
        },
      },
    }
    const adapter = new SandboxMultiplyTransactionAdapter({
      readState: () => multiplyState,
      writeState: (nextState) => {
        multiplyState = nextState
      },
      now: () => 1_718_800_000_000,
      generateId: (() => {
        let count = 0
        return (prefix: string) => `${prefix}-${++count}`
      })(),
    })

    const dangerousIntent = adapter.createIntent({
      type: "multiply",
      walletId: "wallet-2",
      marketId: "eth-usdt",
      collateralAmount: 0.5,
      selectedMultiplier: 7,
    })

    const preview = await adapter.previewTransaction(dangerousIntent)
    const result = await adapter.executeTransaction(dangerousIntent)

    expect(preview.allowed).toBe(false)
    expect(preview.validationErrors.join(" ")).toContain("liquidation threshold")
    expect(result.receipt.status).toBe("failed")
    expect(result.state).toEqual(multiplyState)
    expect(multiplyState.transactions).toHaveLength(0)
  })

  it("simulates multiply and deleverage without touching borrow state", async () => {
    const borrowState = makeExampleBorrowSystemState()
    let multiplyState = makeExampleMultiplySystemState()
    const position = Object.values(multiplyState.positions)[0]!

    const adapter = new SandboxMultiplyTransactionAdapter({
      readState: () => multiplyState,
      writeState: (nextState) => {
        multiplyState = nextState
      },
      now: () => 1_718_800_000_000,
      generateId: (() => {
        let count = 0
        return (prefix: string) => `${prefix}-${++count}`
      })(),
    })

    const multiplyIntent = adapter.createIntent({
      type: "multiply",
      walletId: "wallet-2",
      marketId: "eth-usdt",
      collateralAmount: 0.5,
      selectedMultiplier: 2,
    })
    const multiplyResult = await adapter.executeTransaction(multiplyIntent)
    expect(multiplyResult.receipt.simulated).toBe(true)
    expect(multiplyResult.receipt.status).toBe("success")
    expect(multiplyResult.preview.before.netApy).not.toBeCloseTo(multiplyResult.preview.after.netApy, 6)

    const deleverageIntent = adapter.createIntent({
      type: "deleverage",
      walletId: position.walletId,
      positionId: position.id,
      targetMultiplier: 1.8,
    })
    const deleverageResult = await adapter.executeTransaction(deleverageIntent)
    expect(deleverageResult.receipt.status).toBe("success")
    expect(deleverageResult.preview.after.debtValueUsd).toBeLessThan(deleverageResult.preview.before.debtValueUsd)

    // A reduce/deleverage records a real, nonzero USD amount on its activity row —
    // the size of the unwind (debt repaid), not the ~$0 equity delta. Regression
    // guard for the dashboard All-Transactions "$0"/"-$0.01" reduce rows.
    const debtRepaidUsd = deleverageResult.preview.before.debtValueUsd - deleverageResult.preview.after.debtValueUsd
    expect(deleverageResult.historyItem.amountUsd).toBeGreaterThan(0)
    expect(deleverageResult.historyItem.amountUsd).toBeCloseTo(debtRepaidUsd)

    expect(borrowState.accounts["wallet-1"]?.debtPositions.length).toBeGreaterThan(0)
    expect(Object.keys(multiplyState.positions).length).toBeGreaterThan(0)
  })

  it("keeps repeated multiply actions additive in state and portfolio reads", async () => {
    let multiplyState = makeExampleMultiplySystemState()
    const existing = multiplyState.positions["wallet-1:eth-usdt"]!
    const initialLiquidity = multiplyState.markets[existing.marketId]!.economics.availableLiquidityUsd
    const adapter = new SandboxMultiplyTransactionAdapter({
      readState: () => multiplyState,
      writeState: (nextState) => {
        multiplyState = nextState
      },
      now: () => 1_718_800_000_000,
      generateId: (() => {
        let count = 0
        return (prefix: string) => `${prefix}-${++count}`
      })(),
    })

    const intent = adapter.createIntent({
      type: "multiply",
      walletId: existing.walletId,
      marketId: existing.marketId,
      collateralAmount: 0.5,
      selectedMultiplier: 2,
    })
    const result = await adapter.executeTransaction(intent)
    const updated = multiplyState.positions[existing.id]!
    const readAdapter = new SandboxMultiplyReadAdapter({
      state: multiplyState,
      transactionHistory: [result.historyItem],
    })
    const portfolio = await readAdapter.readPortfolioMultiply(existing.walletId)

    expect(updated.collateralValueUsd).toBeGreaterThan(existing.collateralValueUsd)
    expect(updated.debtValueUsd).toBeGreaterThan(existing.debtValueUsd)
    // The recorded amount is the equity added (what the wallet pays), not the exposure added.
    expect(result.historyItem.amountUsd).toBeCloseTo(
      result.preview.after.collateralValueUsd -
        result.preview.after.debtValueUsd -
        (result.preview.before.collateralValueUsd - result.preview.before.debtValueUsd),
    )
    expect(portfolio.creditLines.totalCollateralUsd).toBeCloseTo(updated.collateralValueUsd)
    expect(portfolio.creditLines.totalBorrowedUsd).toBeCloseTo(updated.debtValueUsd)
    expect(multiplyState.markets[existing.marketId]!.economics.availableLiquidityUsd).toBeCloseTo(
      initialLiquidity - (updated.debtValueUsd - existing.debtValueUsd),
    )
  })

  it("does not commit local state when Convex persistence rejects", async () => {
    let state = makeExampleMultiplySystemState()
    const before = state
    const adapter = new SandboxMultiplyTransactionAdapter({
      readState: () => state,
      writeState: (nextState) => {
        state = nextState
      },
      persistResult: async () => {
        throw new Error("Convex write rejected")
      },
    })
    const intent = adapter.createIntent({
      type: "multiply",
      walletId: "wallet-2",
      marketId: "eth-usdt",
      collateralAmount: 0.5,
      selectedMultiplier: 2,
    })

    await expect(adapter.executeTransaction(intent)).rejects.toThrow("Convex write rejected")
    expect(state).toBe(before)
  })
})
