import { describe, expect, it, vi } from "vitest"
import { ProductionLendReadAdapter } from "@/app/lib/lend-system/production-read-adapter"
import { buildMockLendSystemStateWithSeedPosition } from "@/app/lib/lend-system/mock"
import { buildLendPageData, buildLendWalletSnapshot, buildPortfolioLendData } from "@/app/lib/lend-system/read-model"

describe("ProductionLendReadAdapter", () => {
  it("delegates to injected production readers", async () => {
    const walletId = "wallet-1"
    const state = buildMockLendSystemStateWithSeedPosition(walletId)
    const walletSnapshot = buildLendWalletSnapshot(walletId, state, [])
    const lendPage = buildLendPageData(walletId, state)
    const portfolio = buildPortfolioLendData(walletId, state, [])
    const markets = Object.values(state.markets)

    const adapter = new ProductionLendReadAdapter({
      readWalletSnapshot: vi.fn().mockResolvedValue(walletSnapshot),
      readMarkets: vi.fn().mockResolvedValue(markets),
      readLendPage: vi.fn().mockResolvedValue(lendPage),
      readPortfolioLend: vi.fn().mockResolvedValue(portfolio),
    })

    await expect(adapter.readWalletSnapshot(walletId)).resolves.toEqual(walletSnapshot)
    await expect(adapter.readMarkets()).resolves.toEqual(markets)
    await expect(adapter.readLendPage(walletId)).resolves.toEqual(lendPage)
    await expect(adapter.readPortfolioLend(walletId)).resolves.toEqual(portfolio)
  })

  it("keeps throwing intentionally until real production readers are provided", async () => {
    const adapter = new ProductionLendReadAdapter()

    await expect(adapter.readWalletSnapshot("wallet-1")).rejects.toThrow(
      "Production lend read adapter is not implemented",
    )
    await expect(adapter.readMarkets()).rejects.toThrow("Production lend read adapter is not implemented")
    await expect(adapter.readLendPage("wallet-1")).rejects.toThrow("Production lend read adapter is not implemented")
    await expect(adapter.readPortfolioLend("wallet-1")).rejects.toThrow(
      "Production lend read adapter is not implemented",
    )
  })
})
