import { describe, expect, it, vi } from "vitest"
import { getDefaultWalletProfileId } from "@/app/lib/data/mock/wallet/portfolio/profiles"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { SandboxBorrowReadAdapter } from "@/app/lib/borrow-system/sandbox-read-adapter"
import { ProductionBorrowReadAdapter } from "@/app/lib/borrow-system/production-read-adapter"
import { selectBorrowMarketSummaries } from "@/app/lib/borrow-system/selectors"

describe("borrow read adapters", () => {
  it("reads borrow page, portfolio borrow, wallet snapshot, and detail records from one sandbox contract", async () => {
    const walletId = getDefaultWalletProfileId()
    const state = buildMockBorrowSystemState(walletId)
    const adapter = new SandboxBorrowReadAdapter({ state })

    const [walletSnapshot, markets, borrowPage, portfolioBorrow, poolDetail, assetDetail] = await Promise.all([
      adapter.readWalletSnapshot(walletId),
      adapter.readMarkets(),
      adapter.readBorrowPage(walletId),
      adapter.readPortfolioBorrow(walletId),
      adapter.readPoolDetail("eth-usdc"),
      adapter.readAssetDetail("uni-v3-stable:usdc"),
    ])

    expect(walletSnapshot.walletId).toBe(walletId)
    expect(walletSnapshot.creditSnapshot.collateralValueUsd6).toBeGreaterThan(0n)
    expect(walletSnapshot.transactionHistory).toHaveLength(state.transactions.length)
    expect(walletSnapshot.transactionHistory.every((item) => item.simulated)).toBe(true)

    expect(markets).toHaveLength(Object.keys(state.markets).length)
    expect(borrowPage.walletId).toBe(walletId)
    expect(borrowPage.poolCatalog).toEqual(selectBorrowMarketSummaries(state, walletId))

    expect(portfolioBorrow.creditLines.totalCollateralUsd).toBeGreaterThan(0)
    expect(portfolioBorrow.collateralPositions.length).toBeGreaterThan(0)
    expect(portfolioBorrow.debtPositions.length).toBeGreaterThan(0)

    expect(poolDetail?.hero.name).toBe("WETH / USDC")
    expect(assetDetail?.hero.symbol).toBe("USDC")
  })

  it("prefers canonical persisted transaction history when provided", async () => {
    const walletId = getDefaultWalletProfileId()
    const state = buildMockBorrowSystemState(walletId)
    const adapter = new SandboxBorrowReadAdapter({
      state,
      transactionHistory: [
        {
          id: "history-1",
          intentId: "intent-1",
          walletId,
          marketId: "uni-v3-bluechip-weth-usdc",
          assetId: "uni-v3-bluechip:usdc",
          kind: "borrow",
          status: "success",
          requestedAmountUsd6: 250_000_000n,
          executedAmountUsd6: 250_000_000n,
          simulated: true,
          timestamp: state.now + 1_000,
          hash: "sim_history_1",
        },
      ],
    })

    const snapshot = await adapter.readWalletSnapshot(walletId)

    expect(snapshot.transactionHistory).toHaveLength(1)
    expect(snapshot.transactionHistory[0]?.intentId).toBe("intent-1")
    expect(snapshot.transactionHistory[0]?.hash).toBe("sim_history_1")
  })

  it("exposes a production placeholder that matches the read contract and throws intentionally", async () => {
    const adapter = new ProductionBorrowReadAdapter()

    await expect(adapter.readWalletSnapshot("wallet-1")).rejects.toThrow("Production read adapter is not implemented")
    await expect(adapter.readMarkets()).rejects.toThrow("Production read adapter is not implemented")
    await expect(adapter.readBorrowPage("wallet-1")).rejects.toThrow("Production read adapter is not implemented")
    await expect(adapter.readPortfolioBorrow("wallet-1")).rejects.toThrow("Production read adapter is not implemented")
    await expect(adapter.readPoolDetail("pool-1")).rejects.toThrow("Production read adapter is not implemented")
    await expect(adapter.readAssetDetail("asset-1")).rejects.toThrow("Production read adapter is not implemented")
  })

  it("delegates production reads to the configured source", async () => {
    const walletId = getDefaultWalletProfileId()
    const sandbox = new SandboxBorrowReadAdapter({ state: buildMockBorrowSystemState(walletId) })
    const readWalletSnapshot = vi.fn((id: string) => sandbox.readWalletSnapshot(id))
    const readMarkets = vi.fn(() => sandbox.readMarkets())
    const readBorrowPage = vi.fn((id: string) => sandbox.readBorrowPage(id))
    const readPortfolioBorrow = vi.fn((id: string) => sandbox.readPortfolioBorrow(id))
    const readPoolDetail = vi.fn((id: string) => sandbox.readPoolDetail(id))
    const readAssetDetail = vi.fn((id: string) => sandbox.readAssetDetail(id))
    const adapter = new ProductionBorrowReadAdapter({
      readWalletSnapshot,
      readMarkets,
      readBorrowPage,
      readPortfolioBorrow,
      readPoolDetail,
      readAssetDetail,
    })

    await Promise.all([
      adapter.readWalletSnapshot(walletId),
      adapter.readMarkets(),
      adapter.readBorrowPage(walletId),
      adapter.readPortfolioBorrow(walletId),
      adapter.readPoolDetail("eth-usdc"),
      adapter.readAssetDetail("uni-v3-stable:usdc"),
    ])

    expect(readWalletSnapshot).toHaveBeenCalledWith(walletId)
    expect(readMarkets).toHaveBeenCalledOnce()
    expect(readBorrowPage).toHaveBeenCalledWith(walletId)
    expect(readPortfolioBorrow).toHaveBeenCalledWith(walletId)
    expect(readPoolDetail).toHaveBeenCalledWith("eth-usdc")
    expect(readAssetDetail).toHaveBeenCalledWith("uni-v3-stable:usdc")
  })
})
