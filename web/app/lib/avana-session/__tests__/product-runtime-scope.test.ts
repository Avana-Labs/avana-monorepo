import { describe, expect, it } from "vitest"
import { resolveProductRuntimeScope } from "@/app/lib/avana-session/product-runtime-scope"

describe("resolveProductRuntimeScope", () => {
  it("keeps Borrow off Rewards, Swap, and Umbrella subscriptions", () => {
    const scope = resolveProductRuntimeScope("/borrow")
    expect(scope.walletSession).toBe(true)
    expect(scope.marketSnapshots).toBe(true)
    expect(scope.hydrateBorrowMarkets).toBe(true)
    expect(scope.hydrateLendMarkets).toBe(false)
    expect(scope.hydrateMultiplyMarkets).toBe(false)
    expect(scope.swapTransactions).toBe(false)
    expect(scope.rewards).toBe(false)
    expect(scope.umbrella).toBe(false)
  })

  it("scopes Lend / Multiply / Swap / Umbrella to their own remotes", () => {
    expect(resolveProductRuntimeScope("/lend").hydrateLendMarkets).toBe(true)
    expect(resolveProductRuntimeScope("/lend").swapTransactions).toBe(false)
    expect(resolveProductRuntimeScope("/multiply").hydrateMultiplyMarkets).toBe(true)
    expect(resolveProductRuntimeScope("/swap")).toMatchObject({
      walletSession: true,
      swapTransactions: true,
      marketSnapshots: false,
      rewards: false,
      umbrella: false,
    })
    expect(resolveProductRuntimeScope("/umbrella")).toMatchObject({
      umbrella: true,
      walletSession: false,
      swapTransactions: false,
      rewards: false,
    })
  })

  it("loads the Multiply market catalog needed by the consolidated dashboard", () => {
    expect(resolveProductRuntimeScope("/dashboard")).toMatchObject({
      walletSession: true,
      rewards: true,
      umbrella: true,
      swapTransactions: false,
      marketSnapshots: true,
      hydrateMultiplyMarkets: true,
    })
  })

  it("counts at most three session-provider subscriptions on Borrow", () => {
    const scope = resolveProductRuntimeScope("/borrow/pool/foo")
    const sessionSubscriptions = [
      scope.walletSession, // getSessionState
      scope.walletSession, // listForWallet (same gate)
      scope.marketSnapshots, // listMarketSnapshots
      scope.swapTransactions,
      scope.rewards,
      scope.umbrella,
    ].filter(Boolean).length
    // walletSession opens two queries; marketSnapshots opens one → 3. Remotes stay off.
    expect(sessionSubscriptions).toBe(3)
    expect(scope.swapTransactions || scope.rewards || scope.umbrella).toBe(false)
  })
})

describe("market snapshot hydrator price source", () => {
  it("does not open a duplicate getPriceSnapshot subscription", async () => {
    const { readFileSync } = await import("node:fs")
    const { resolve } = await import("node:path")
    const source = readFileSync(resolve(__dirname, "../convex-market-snapshot-hydrators.tsx"), "utf8")
    expect(source).not.toMatch(/api\.prices\./)
    expect(source).toMatch(/usePriceFor/)
    expect(source).toMatch(/scope\.marketSnapshots \? \{\} : "skip"/)
  })
})
