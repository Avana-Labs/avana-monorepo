import { describe, expect, it } from "vitest"
import { parseFixed, type BorrowAction } from "@/app/lib/borrow-system/model"
import { SandboxTransactionAdapter } from "@/app/lib/borrow-system/sandbox-transaction-adapter"
import {
  EXAMPLE_UNI_MARKET_ID,
  EXAMPLE_UNI_USDC_ASSET_ID,
  EXAMPLE_WALLET_1_DEBT_ID,
  makeExampleBorrowSystemState,
} from "@/app/lib/borrow-system/model/__tests__/fixtures"
import { assertSandboxActionContract } from "./sandbox-adapter-contract"

function createHarness() {
  const seed = makeExampleBorrowSystemState()
  let state = seed

  const adapter = new SandboxTransactionAdapter({
    readState: () => state,
    writeState: (nextState) => {
      state = nextState
    },
    now: () => 1_718_800_000_000,
    generateId: (() => {
      let count = 0
      return (prefix: string) => `${prefix}-${++count}`
    })(),
  })

  return {
    adapter,
    seed,
    getState: () => state,
    replaceState: (nextState: typeof state) => {
      state = nextState
    },
  }
}

describe("sandbox transaction adapter", () => {
  it("rejects execution when state changed after the quote was created", async () => {
    const harness = createHarness()
    const intent = harness.adapter.createIntent({
      type: "borrow",
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      assetId: EXAMPLE_UNI_USDC_ASSET_ID,
      amountUsd6: parseFixed("100", 6),
    })

    await harness.adapter.previewTransaction(intent)
    harness.replaceState({ ...harness.getState(), now: harness.getState().now + 1 })

    await expect(harness.adapter.executeTransaction(intent)).rejects.toThrow("Quote is stale")
  })

  it("deposit LP satisfies the sandbox action contract", async () => {
    const harness = createHarness()
    const action: BorrowAction = {
      type: "supplyCollateral",
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      amountUsd6: parseFixed("1000", 6),
    }

    const { preview, result } = await assertSandboxActionContract(harness, action, {
      expectedActionType: "deposit",
      walletId: "wallet-1",
    })

    expect(preview.after.collateralValueUsd6).toBeGreaterThan(preview.before.collateralValueUsd6)
    expect(result.state.transactions.at(-1)?.kind).toBe("deposit")
  })

  it("borrow satisfies the sandbox action contract", async () => {
    const harness = createHarness()
    const action: BorrowAction = {
      type: "borrow",
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      assetId: EXAMPLE_UNI_USDC_ASSET_ID,
      amountUsd6: parseFixed("300", 6),
    }

    const { preview, result } = await assertSandboxActionContract(harness, action, {
      expectedActionType: "borrow",
      walletId: "wallet-1",
    })

    expect(preview.after.totalBorrowedUsd6).toBeGreaterThan(preview.before.totalBorrowedUsd6)
    expect(result.state.accounts["wallet-1"]!.debtPositions[0]!.principalBorrowedUsd6).toBeGreaterThan(
      parseFixed("4200", 6),
    )
  })

  it("normalizes short borrow asset ids to the selected market spoke", async () => {
    const harness = createHarness()
    const intent = harness.adapter.createIntent({
      type: "borrow",
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      assetId: "usdc",
      amountUsd6: parseFixed("100", 6),
    })

    expect(intent.assetId).toBe(EXAMPLE_UNI_USDC_ASSET_ID)
    const preview = await harness.adapter.previewTransaction(intent)
    expect(preview.allowed).toBe(true)
    expect(preview.validationErrors).not.toContain(`Asset usdc does not belong to spoke uni-v3-bluechip`)
  })

  it("repay satisfies the sandbox action contract", async () => {
    const harness = createHarness()
    const action: BorrowAction = {
      type: "repay",
      walletId: "wallet-1",
      debtPositionId: EXAMPLE_WALLET_1_DEBT_ID,
      amountUsd6: parseFixed("250", 6),
    }

    const { preview, result } = await assertSandboxActionContract(harness, action, {
      expectedActionType: "repay",
      walletId: "wallet-1",
    })

    expect(preview.after.totalBorrowedUsd6).toBeLessThan(preview.before.totalBorrowedUsd6)
    expect(result.state.transactions.at(-1)?.kind).toBe("repay")
  })

  it("carries the selected debt asset into repayment history", () => {
    const harness = createHarness()
    const intent = harness.adapter.createIntent({
      type: "repay",
      walletId: "wallet-1",
      debtPositionId: EXAMPLE_WALLET_1_DEBT_ID,
      amountUsd6: parseFixed("100", 6),
    })

    expect(intent.assetId).toBe(EXAMPLE_UNI_USDC_ASSET_ID)
  })

  it("claim satisfies the sandbox action contract", async () => {
    const harness = createHarness()
    const beforeBalance = harness.getState().accounts["wallet-1"]!.walletBalanceUsd6
    const action: BorrowAction = {
      type: "claim",
      walletId: "wallet-1",
      rewardPositionIds: ["claim-eth-usdc"],
      amountUsd6: parseFixed("80", 6),
    }

    const { preview, result } = await assertSandboxActionContract(harness, action, {
      expectedActionType: "claim",
      walletId: "wallet-1",
    })

    expect(preview.allowed).toBe(true)
    expect(preview.before.totalBorrowedUsd6).toBe(preview.after.totalBorrowedUsd6)
    expect(result.state.accounts["wallet-1"]!.walletBalanceUsd6).toBe(beforeBalance + parseFixed("80", 6))
    expect(result.historyItem.kind).toBe("claim")
  })

  it("withdraw satisfies the sandbox action contract for safe removals", async () => {
    const harness = createHarness()
    const action: BorrowAction = {
      type: "removeCollateral",
      walletId: "wallet-1",
      positionId: "wallet-1:weth-usdc",
      amountUsd6: parseFixed("1000", 6),
    }

    const { preview, result } = await assertSandboxActionContract(harness, action, {
      expectedActionType: "withdraw",
      walletId: "wallet-1",
    })

    expect(preview.after.collateralValueUsd6).toBeLessThan(preview.before.collateralValueUsd6)
    expect(result.historyItem.kind).toBe("withdraw")
  })

  it("records the executed USD amount for percent-based collateral removals", async () => {
    const harness = createHarness()
    const action: BorrowAction = {
      type: "removeCollateral",
      walletId: "wallet-1",
      positionId: "wallet-1:weth-usdc",
      percentBps: 1_000,
    }

    const intent = harness.adapter.createIntent(action)
    const preview = await harness.adapter.previewTransaction(intent)
    const result = await harness.adapter.executeTransaction(intent)

    expect(result.receipt.status).toBe("success")
    expect(result.historyItem.executedAmountUsd6).toBe(
      preview.before.collateralValueUsd6 - preview.after.collateralValueUsd6,
    )
    expect(result.historyItem.executedAmountUsd6).toBeGreaterThan(0n)
  })

  it("blocks unsafe withdraw before mutating sandbox state", async () => {
    const harness = createHarness()
    const beforeTransactions = harness.getState().transactions.length
    const action: BorrowAction = {
      type: "removeCollateral",
      walletId: "wallet-1",
      positionId: "wallet-1:weth-usdc",
      percentBps: 10_000,
    }

    await assertSandboxActionContract(harness, action, {
      expectedActionType: "withdraw",
      walletId: "wallet-1",
    })

    expect(harness.getState().transactions).toHaveLength(beforeTransactions)
  })

  it("does not commit local state when Convex persistence rejects", async () => {
    let state = makeExampleBorrowSystemState()
    const before = state
    const adapter = new SandboxTransactionAdapter({
      readState: () => state,
      writeState: (nextState) => {
        state = nextState
      },
      persistResult: async () => {
        throw new Error("Convex write rejected")
      },
    })
    const intent = adapter.createIntent({
      type: "borrow",
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      assetId: EXAMPLE_UNI_USDC_ASSET_ID,
      amountUsd6: parseFixed("300", 6),
    })

    await expect(adapter.executeTransaction(intent)).rejects.toThrow("Convex write rejected")
    expect(state).toBe(before)
  })

  it("records failed actions through persistResult (best-effort) and still returns the receipt", async () => {
    let state = makeExampleBorrowSystemState()
    const persistCalls: string[] = []
    const adapter = new SandboxTransactionAdapter({
      readState: () => state,
      writeState: (nextState) => {
        state = nextState
      },
      persistResult: async (result) => {
        persistCalls.push(result.receipt.status)
        // Mirror a backend that records the failure and echoes it back.
        return {
          id: "persisted-fail",
          hash: "0xpersisted",
          status: result.receipt.status,
          simulated: true,
          timestamp: 1,
        }
      },
    })
    // Liquidation is always a failed (preview-only) action in the sandbox.
    const intent = adapter.createIntent({
      type: "liquidate",
      walletId: "wallet-1",
      positionId: "wallet-1:weth-usdc",
      repayAssetId: EXAMPLE_UNI_USDC_ASSET_ID,
      repayAmountUsd6: parseFixed("100", 6),
      debtPositionId: EXAMPLE_WALLET_1_DEBT_ID,
    } as BorrowAction)

    const result = await adapter.executeTransaction(intent)
    expect(persistCalls).toEqual(["failed"])
    expect(result.receipt.status).toBe("failed")
    expect(result.historyItem.status).toBe("failed")
    expect(result.historyItem.hash).toBe("0xpersisted")
  })

  it("keeps a failed receipt even when persistence of the failure throws", async () => {
    let state = makeExampleBorrowSystemState()
    const adapter = new SandboxTransactionAdapter({
      readState: () => state,
      writeState: (nextState) => {
        state = nextState
      },
      persistResult: async () => {
        throw new Error("backend unavailable")
      },
    })
    const intent = adapter.createIntent({
      type: "liquidate",
      walletId: "wallet-1",
      positionId: "wallet-1:weth-usdc",
      repayAssetId: EXAMPLE_UNI_USDC_ASSET_ID,
      repayAmountUsd6: parseFixed("100", 6),
      debtPositionId: EXAMPLE_WALLET_1_DEBT_ID,
    } as BorrowAction)

    // Best-effort: a failed action whose persistence fails does not reject.
    const result = await adapter.executeTransaction(intent)
    expect(result.receipt.status).toBe("failed")
  })

  it("liquidation preview does not mutate state and execute remains preview-only", async () => {
    const harness = createHarness()
    const state = harness.getState()
    state.accounts["wallet-1"]!.debtPositions[0]!.principalBorrowedUsd6 = parseFixed("18000", 6)
    state.accounts["wallet-1"]!.debtPositions[0]!.debtSharesUsd6 = parseFixed("18000", 6)
    const beforeTransactions = state.transactions.length

    const action: BorrowAction = {
      type: "liquidate",
      walletId: "wallet-1",
      positionId: "wallet-1:weth-usdc",
      debtPositionId: EXAMPLE_WALLET_1_DEBT_ID,
      repayAmountUsd6: parseFixed("2000", 6),
    }

    const { preview, result } = await assertSandboxActionContract(harness, action, {
      expectedActionType: "liquidate",
      previewOnly: true,
      walletId: "wallet-1",
    })

    expect(preview.allowed).toBe(true)
    expect(preview.riskLabel).toBe("danger")
    expect(result.receipt.error).toContain("preview-only")
    expect(harness.getState().transactions).toHaveLength(beforeTransactions)
  })

  it("reuses cached preview evaluation during execute", async () => {
    const harness = createHarness()
    const action: BorrowAction = {
      type: "borrow",
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      assetId: EXAMPLE_UNI_USDC_ASSET_ID,
      amountUsd6: parseFixed("300", 6),
    }

    const intent = harness.adapter.createIntent(action)
    const preview = await harness.adapter.previewTransaction(intent)
    const result = await harness.adapter.executeTransaction(intent)

    expect(result.preview).toBe(preview)
  })

  it("resets sandbox state back to the original seed", async () => {
    const harness = createHarness()
    const action: BorrowAction = {
      type: "borrow",
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      assetId: EXAMPLE_UNI_USDC_ASSET_ID,
      amountUsd6: parseFixed("300", 6),
    }

    await assertSandboxActionContract(harness, action, {
      expectedActionType: "borrow",
      walletId: "wallet-1",
    })
    expect(harness.getState().transactions.length).toBeGreaterThan(harness.seed.transactions.length)

    harness.adapter.resetSandboxState()
    expect(harness.getState()).toEqual(harness.seed)
  })
})
