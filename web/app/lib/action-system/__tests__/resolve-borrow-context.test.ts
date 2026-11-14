import { describe, expect, it } from "vitest"
import {
  borrowSelectItemsForMarket,
  repaySelectItemsForWallet,
  supplySelectItemsForWallet,
} from "@/app/lib/action-system/resolve-borrow-context"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { selectBorrowMarketSummaries } from "@/app/lib/borrow-system/selectors"
import { RAY, parseFixed } from "@/app/lib/borrow-system/model"

describe("resolve borrow context", () => {
  it("only lists supply pools with wallet LP balances", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const session = {
      state,
      marketSummaries: selectBorrowMarketSummaries(state, "demo-wallet"),
      collateralPools: [],
      getBorrowableAssetsForMarket: () => [],
      borrowableAssets: [],
    }

    const items = supplySelectItemsForWallet(session, "demo-wallet")
    const ids = items.map((item) => item.id)

    expect(ids).toContain("uni-v3-bluechip-weth-usdc")
    expect(ids).toContain("uni-v3-stable-usdc-usdt")
    expect(items[0]?.pairSymbols?.length).toBe(2)
  })

  it("uses current debt value for repay labels", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const debt = state.accounts["demo-wallet"]!.debtPositions[0]!
    debt.principalBorrowedUsd6 = parseFixed("1000", 6)
    debt.debtSharesUsd6 = parseFixed("1000", 6)
    debt.debtIndexRay = RAY + parseFixed("0.25", 27)

    const session = {
      state,
      marketSummaries: selectBorrowMarketSummaries(state, "demo-wallet"),
      collateralPools: [],
      getBorrowableAssetsForMarket: () => [],
      borrowableAssets: [],
    }

    const items = repaySelectItemsForWallet(session, "demo-wallet", session.state.now)
    expect(items[0]?.trailingLabel).toContain("$1,250")
  })

  it("labels each borrowable asset with its own liquidity, not one global credit figure", () => {
    // Two assets with distinct on-market liquidity — the old code min-capped both
    // against the account's single borrowing power, printing the same number twice.
    const state = {
      assets: {
        usdc: { snapshot: { availableLiquidityUsd6: parseFixed("9900000", 6) } },
        gho: { snapshot: { availableLiquidityUsd6: parseFixed("2500000", 6) } },
      },
    } as unknown as Parameters<typeof borrowSelectItemsForMarket>[0]["state"]

    const session = {
      state,
      marketSummaries: [],
      collateralPools: [],
      borrowableAssets: [],
      getBorrowableAssetsForMarket: () => [
        { id: "usdc", name: "USD Coin", symbol: "USDC", borrowApr: 5.2 },
        { id: "gho", name: "GHO", symbol: "GHO", borrowApr: 4.1 },
      ],
    }

    const items = borrowSelectItemsForMarket(session, "uni-v3-bluechip", "demo-wallet")

    expect(items.map((item) => item.trailingLabel)).toEqual(["$9.9M liquidity", "$2.5M liquidity"])
    // The two rows must not read the same figure.
    expect(items[0]?.trailingLabel).not.toBe(items[1]?.trailingLabel)
  })

  it("labels the borrow-rate fallback as APR, not APY (sandbox accrual is linear)", () => {
    // No asset liquidity in state → the trailing label falls back to the borrow rate,
    // which is an APR and must be labelled as such.
    const session = {
      state: { assets: {} } as unknown as Parameters<typeof borrowSelectItemsForMarket>[0]["state"],
      marketSummaries: [],
      collateralPools: [],
      borrowableAssets: [],
      getBorrowableAssetsForMarket: () => [{ id: "gho", name: "GHO", symbol: "GHO", borrowApr: 4.1 }],
    }

    const items = borrowSelectItemsForMarket(session, "uni-v3-bluechip", "demo-wallet")
    expect(items[0]?.trailingLabel).toBe("4.10% APR")
    expect(items[0]?.trailingLabel).not.toContain("APY")
  })
})
