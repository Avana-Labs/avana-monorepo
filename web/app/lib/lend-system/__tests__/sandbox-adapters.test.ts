import { describe, expect, it } from "vitest"
import { buildMockLendSystemState, buildMockLendSystemStateWithSeedPosition } from "@/app/lib/lend-system/mock"
import { SandboxLendReadAdapter } from "@/app/lib/lend-system/sandbox-read-adapter"
import { SandboxLendTransactionAdapter } from "@/app/lib/lend-system/sandbox-transaction-adapter"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { buildMockMultiplySystemState } from "@/app/lib/multiply-system/mock"
import { getWalletLendAssets } from "@/app/lib/data/mock/wallet/portfolio/lend-wallet-assets"

describe("SandboxLendReadAdapter", () => {
  it("loads markets and wallet positions", async () => {
    const state = buildMockLendSystemStateWithSeedPosition("wallet-1")
    const adapter = new SandboxLendReadAdapter({ state })

    const markets = await adapter.readMarkets()
    const page = await adapter.readLendPage("wallet-1")
    const portfolio = await adapter.readPortfolioLend("wallet-1")

    expect(markets.length).toBeGreaterThan(10)
    expect(page.featuredSnapshots.length).toBe(3)
    expect(page.assetGroups.flatMap((group) => group.rows).length).toBeGreaterThan(10)
    expect(portfolio.investments.length).toBe(1)
  })

  it("surfaces non-zero rewards APY for boosted lend markets", async () => {
    const state = buildMockLendSystemState("wallet-1")
    const adapter = new SandboxLendReadAdapter({ state })

    const page = await adapter.readLendPage("wallet-1")
    const boosted = page.assetGroups.flatMap((group) => group.rows).find((row) => row.symbol === "USDG")

    expect(boosted?.rewardsApyValue).toBeGreaterThan(0)
    expect(boosted?.rewardsApyLabel).not.toBe("0.00%")
  })

  it("seeds wallet balances from the shared wallet lend asset source", async () => {
    const state = buildMockLendSystemState("demo-wallet")
    const walletAssets = getWalletLendAssets("demo-wallet")

    expect(state.walletBalances["demo-wallet"]?.usdc).toBe(
      walletAssets.find((asset) => asset.symbol === "USDC")?.balance,
    )
    expect(state.walletBalances["demo-wallet"]?.eth).toBe(walletAssets.find((asset) => asset.symbol === "ETH")?.balance)
    expect(state.walletBalances["demo-wallet"]?.usdt).toBe(
      walletAssets.find((asset) => asset.symbol === "USDT")?.balance,
    )
  })
})

describe("SandboxLendTransactionAdapter", () => {
  it("simulates deposit and withdraw without touching borrow or multiply state", async () => {
    const borrowBefore = buildMockBorrowSystemState("wallet-1")
    const multiplyBefore = buildMockMultiplySystemState("wallet-1")
    let state = buildMockLendSystemState("wallet-1")

    const adapter = new SandboxLendTransactionAdapter({
      readState: () => state,
      writeState: (next) => {
        state = next
      },
      now: () => state.now,
      generateId: (prefix) => `${prefix}-test`,
    })

    const depositIntent = adapter.createIntent({
      type: "deposit",
      walletId: "wallet-1",
      marketId: "eth",
      depositAmount: 1,
      walletBalance: state.walletBalances["wallet-1"]?.eth,
    })
    const depositResult = await adapter.executeTransaction(depositIntent)

    expect(depositResult.historyItem.kind).toBe("deposit")
    expect(Object.keys(depositResult.state.positions).length).toBe(1)

    const positionId = Object.keys(depositResult.state.positions)[0]!
    const withdrawIntent = adapter.createIntent({
      type: "withdraw",
      walletId: "wallet-1",
      marketId: "eth",
      positionId,
      withdrawAmount: 0.5,
    })
    const withdrawResult = await adapter.executeTransaction(withdrawIntent)

    expect(withdrawResult.historyItem.kind).toBe("withdraw")
    expect(withdrawResult.state.transactions.length).toBe(2)
    expect(buildMockBorrowSystemState("wallet-1").positions).toEqual(borrowBefore.positions)
    expect(buildMockMultiplySystemState("wallet-1").positions).toEqual(multiplyBefore.positions)
  })

  it("claims wallet-level lend rewards through the transaction adapter", async () => {
    let state = buildMockLendSystemStateWithSeedPosition("wallet-1")
    state.positions["wallet-1:eth"] = {
      ...state.positions["wallet-1:eth"]!,
      rewardsEarnedUsd: 88,
    }

    const adapter = new SandboxLendTransactionAdapter({
      readState: () => state,
      writeState: (next) => {
        state = next
      },
      now: () => state.now,
      generateId: (prefix) => `${prefix}-claim`,
    })

    const intent = adapter.createIntent({
      type: "claim",
      walletId: "wallet-1",
    })

    const preview = await adapter.previewTransaction(intent)
    expect(preview.allowed).toBe(true)
    expect(preview.before.rewardsEarnedUsd).toBe(88)
    expect(preview.after.rewardsEarnedUsd).toBe(0)

    const result = await adapter.executeTransaction(intent)

    expect(result.historyItem.kind).toBe("claim")
    expect(result.state.positions["wallet-1:eth"]?.rewardsEarnedUsd).toBe(0)
  })

  it("blocks redepositing funds that were already supplied from the wallet balance", async () => {
    let state = buildMockLendSystemState("wallet-1")
    state.walletBalances["wallet-1"] = { ...(state.walletBalances["wallet-1"] ?? {}), eth: 1.28 }
    let nextId = 0

    const adapter = new SandboxLendTransactionAdapter({
      readState: () => state,
      writeState: (next) => {
        state = next
      },
      now: () => state.now,
      generateId: (prefix) => `${prefix}-wallet-${nextId++}`,
    })

    const firstDeposit = adapter.createIntent({
      type: "deposit",
      walletId: "wallet-1",
      marketId: "eth",
      depositAmount: 1,
      walletBalance: state.walletBalances["wallet-1"]!.eth,
    })
    await adapter.executeTransaction(firstDeposit)

    const secondDeposit = adapter.createIntent({
      type: "deposit",
      walletId: "wallet-1",
      marketId: "eth",
      depositAmount: 0.5,
      walletBalance: state.walletBalances["wallet-1"]!.eth,
    })
    const preview = await adapter.previewTransaction(secondDeposit)

    expect(state.walletBalances["wallet-1"]!.eth).toBeCloseTo(0.28, 6)
    expect(preview.allowed).toBe(false)
    expect(preview.validationErrors[0]).toContain("Insufficient wallet balance")
  })

  it("revalidates deposits against the current wallet balance at execution time", async () => {
    let state = buildMockLendSystemState("wallet-1")
    state.walletBalances["wallet-1"] = { ...(state.walletBalances["wallet-1"] ?? {}), eth: 1 }

    const adapter = new SandboxLendTransactionAdapter({
      readState: () => state,
      writeState: (next) => {
        state = next
      },
      now: () => state.now,
      generateId: (prefix) => `${prefix}-stale-balance`,
    })

    const intent = adapter.createIntent({
      type: "deposit",
      walletId: "wallet-1",
      marketId: "eth",
      depositAmount: 1,
      walletBalance: 1,
    })

    await expect(adapter.previewTransaction(intent)).resolves.toMatchObject({ allowed: true })

    state = {
      ...state,
      walletBalances: {
        ...state.walletBalances,
        "wallet-1": { ...(state.walletBalances["wallet-1"] ?? {}), eth: 0 },
      },
    }

    // A blocked-at-execution lend is recorded as a failed result (like
    // borrow/multiply), not thrown, so it appears in activity.
    const result = await adapter.executeTransaction(intent)
    expect(result.receipt.status).toBe("failed")
    expect(result.receipt.error).toContain("Insufficient wallet balance")
    expect(result.historyItem.status).toBe("failed")
    // No phantom position and no committed state from a failure.
    expect(Object.keys(result.state.positions)).toHaveLength(0)
    expect(result.state.transactions).toHaveLength(0)
    expect(Object.keys(state.positions)).toHaveLength(0)
    expect(state.transactions).toHaveLength(0)
  })

  it("persists a failed lend receipt through the backend before returning", async () => {
    let state = buildMockLendSystemState("wallet-1")
    state.walletBalances["wallet-1"] = { ...(state.walletBalances["wallet-1"] ?? {}), eth: 0 }
    const persisted: unknown[] = []

    const adapter = new SandboxLendTransactionAdapter({
      readState: () => state,
      writeState: (next) => {
        state = next
      },
      now: () => state.now,
      generateId: (prefix) => `${prefix}-fail`,
      persistResult: async (result) => {
        persisted.push(result)
        return {
          id: "persisted-fail",
          hash: "persisted-hash",
          status: "failed" as const,
          actionType: result.receipt.actionType,
          simulated: true,
          timestamp: result.receipt.timestamp,
        }
      },
    })

    const intent = adapter.createIntent({
      type: "deposit",
      walletId: "wallet-1",
      marketId: "eth",
      depositAmount: 1,
      walletBalance: 1,
    })

    const result = await adapter.executeTransaction(intent)

    expect(persisted).toHaveLength(1)
    expect(result.receipt.status).toBe("failed")
    expect(result.receipt.id).toBe("persisted-fail")
    expect(result.historyItem.status).toBe("failed")
  })

  it("does not commit local state when Convex persistence rejects", async () => {
    let state = buildMockLendSystemState("wallet-1")
    state.walletBalances["wallet-1"] = { ...(state.walletBalances["wallet-1"] ?? {}), eth: 1 }
    const before = state
    const adapter = new SandboxLendTransactionAdapter({
      readState: () => state,
      writeState: (nextState) => {
        state = nextState
      },
      persistResult: async () => {
        throw new Error("Convex write rejected")
      },
    })
    const intent = adapter.createIntent({
      type: "deposit",
      walletId: "wallet-1",
      marketId: "eth",
      depositAmount: 0.5,
      walletBalance: 1,
    })

    await expect(adapter.executeTransaction(intent)).rejects.toThrow("Convex write rejected")
    expect(state).toBe(before)
  })
})
