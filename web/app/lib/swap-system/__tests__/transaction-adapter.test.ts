import { describe, expect, it } from "vitest"
import { MockSwapProvider, SandboxSwapTransactionAdapter, type SwapSystemState } from "@/app/lib/swap-system"

function setup() {
  let state: SwapSystemState = {
    balances: [
      { id: "wallet-eth", walletId: "demo-wallet", assetId: "eth", amount: 2, sourceType: "wallet" },
      { id: "wallet-usdc", walletId: "demo-wallet", assetId: "usdc", amount: 1000, sourceType: "wallet" },
      { id: "active-eth", walletId: "demo-wallet", assetId: "eth", amount: 3, sourceType: "multiply_active" },
    ],
    allowances: {},
    transactions: [],
  }
  const adapter = new SandboxSwapTransactionAdapter({
    readState: () => state,
    writeState: (next) => {
      state = next
    },
    provider: new MockSwapProvider({ now: () => 1_000, quoteTtlMs: 20_000 }),
    now: () => 1_000,
    generateId: (prefix) => `${prefix}-1`,
  })

  return { adapter, getState: () => state }
}

describe("SandboxSwapTransactionAdapter", () => {
  it("bypasses approval for native assets and updates wallet balances on confirmation", async () => {
    const { adapter, getState } = setup()
    const quote = await adapter.provider.getQuote({
      walletId: "demo-wallet",
      chainId: 1,
      inputAssetId: "eth",
      outputAssetId: "usdc",
      inputAmount: 1,
      slippageBps: 50,
    })

    expect(adapter.requiresApproval("demo-wallet", "eth", 1)).toBe(false)

    const result = await adapter.executeSwap(quote, "demo-wallet")

    expect(result.status).toBe("confirmed")
    expect(getState().balances.find((balance) => balance.id === "wallet-eth")?.amount).toBe(1)
    expect(getState().balances.find((balance) => balance.id === "active-eth")?.amount).toBe(3)
    expect(getState().balances.find((balance) => balance.id === "wallet-usdc")?.amount).toBeCloseTo(2899.187)
    expect(getState().transactions).toHaveLength(1)
  })

  it("requires ERC-20 approval before swap execution", async () => {
    const { adapter, getState } = setup()
    const quote = await adapter.provider.getQuote({
      walletId: "demo-wallet",
      chainId: 1,
      inputAssetId: "usdc",
      outputAssetId: "eth",
      inputAmount: 100,
      slippageBps: 50,
    })

    expect(adapter.requiresApproval("demo-wallet", "usdc", 100)).toBe(true)
    await expect(adapter.executeSwap(quote, "demo-wallet")).resolves.toMatchObject({
      status: "approval_pending",
      failureReason: "Token approval required.",
    })
    expect(getState().balances.find((balance) => balance.id === "wallet-usdc")?.amount).toBe(1000)

    await expect(adapter.approve("demo-wallet", "usdc", 100)).resolves.toMatchObject({
      status: "approval_confirmed",
    })
    expect(adapter.requiresApproval("demo-wallet", "usdc", 100)).toBe(false)
    await expect(adapter.executeSwap(quote, "demo-wallet")).resolves.toMatchObject({ status: "confirmed" })
    expect(getState().balances.find((balance) => balance.id === "wallet-usdc")?.amount).toBe(900)
  })

  it("does not initiate a swap after rejected or failed approval", async () => {
    const { adapter, getState } = setup()

    await expect(adapter.approve("demo-wallet", "usdc", 100, { rejectApproval: true })).resolves.toMatchObject({
      status: "rejected",
    })
    expect(adapter.requiresApproval("demo-wallet", "usdc", 100)).toBe(true)

    await expect(adapter.approve("demo-wallet", "usdc", 100, { failApproval: true })).resolves.toMatchObject({
      status: "failed",
    })
    expect(getState().transactions).toHaveLength(0)
  })

  it("blocks expired quotes and leaves balances unchanged", async () => {
    const { adapter, getState } = setup()
    const quote = await adapter.provider.getQuote({
      walletId: "demo-wallet",
      chainId: 1,
      inputAssetId: "eth",
      outputAssetId: "usdc",
      inputAmount: 1,
      slippageBps: 50,
    })

    await expect(adapter.executeSwap(quote, "demo-wallet", { now: 21_000 })).resolves.toMatchObject({
      status: "expired",
    })
    expect(getState().balances.find((balance) => balance.id === "wallet-eth")?.amount).toBe(2)
  })

  it("does not modify balances on rejected or reverted swaps", async () => {
    const { adapter, getState } = setup()
    const quote = await adapter.provider.getQuote({
      walletId: "demo-wallet",
      chainId: 1,
      inputAssetId: "eth",
      outputAssetId: "usdc",
      inputAmount: 1,
      slippageBps: 50,
    })

    await expect(adapter.executeSwap(quote, "demo-wallet", { rejectSwap: true })).resolves.toMatchObject({
      status: "rejected",
    })
    await expect(adapter.executeSwap(quote, "demo-wallet", { revertSwap: true })).resolves.toMatchObject({
      status: "failed",
    })
    expect(getState().balances.find((balance) => balance.id === "wallet-eth")?.amount).toBe(2)
    expect(getState().balances.find((balance) => balance.id === "wallet-usdc")?.amount).toBe(1000)
  })
})
