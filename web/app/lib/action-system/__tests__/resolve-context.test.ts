import { describe, expect, it } from "vitest"
import {
  claimSelectItemsForWallet,
  repaySelectItemsForWallet,
  resolveBorrowAssetId,
  resolveBorrowMarketForAsset,
  resolveBorrowTokenSelection,
} from "@/app/lib/action-system/resolve-borrow-context"
import { lendWithdrawSelectItems } from "@/app/lib/action-system/resolve-lend-context"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { RAY, parseFixed } from "@/app/lib/credit-engine"

describe("resolveBorrowAssetId", () => {
  it("maps short asset params to scoped engine ids", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const marketId = "uni-v3-bluechip-weth-usdc"
    expect(resolveBorrowAssetId(state, "usdc", marketId)).toBe("uni-v3-bluechip:usdc")
    expect(resolveBorrowAssetId(state, "uni-v3-bluechip:usdc", marketId)).toBe("uni-v3-bluechip:usdc")
  })

  it("keeps short asset params scoped to the selected market spoke", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const bluechipMarket = "uni-v3-bluechip-weth-usdc"
    const stableMarket = "uni-v3-stable-usdc-usdt"

    expect(resolveBorrowAssetId(state, "usdc", bluechipMarket)).toBe("uni-v3-bluechip:usdc")
    expect(resolveBorrowAssetId(state, "usdc", stableMarket)).toBe("uni-v3-stable:usdc")
  })

  it("returns empty when the asset is not borrowable in the selected market", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    expect(resolveBorrowAssetId(state, "wbtc", "uni-v3-stable-usdc-usdt")).toBe("")
  })

  it("routes unsupported short asset params to a supported borrow market", () => {
    const session = {
      state: buildMockBorrowSystemState("demo-wallet"),
      marketSummaries: [
        { id: "uni-v3-bluechip-weth-usdc", name: "WETH / USDC", venue: "Uni v3 Bluechip", feeTier: "0.05%" },
        { id: "uni-v3-bluechip-wbtc-weth", name: "WBTC / WETH", venue: "Uni v3 Bluechip", feeTier: "0.05%" },
        { id: "uni-v3-stable-usdc-usdt", name: "USDC / USDT", venue: "Uni v3 Stable", feeTier: "0.01%" },
      ],
      collateralPools: [
        { id: "uni-v3-bluechip-weth-usdc" },
        { id: "uni-v3-bluechip-wbtc-weth" },
        { id: "uni-v3-stable-usdc-usdt" },
      ],
      getBorrowableAssetsForMarket: () => [],
      borrowableAssets: [],
    }

    expect(resolveBorrowMarketForAsset(session as never, "gho", "uni-v3-bluechip-weth-usdc")).toBe(
      "uni-v3-stable-usdc-usdt",
    )
    expect(resolveBorrowTokenSelection(session as never, "gho", "uni-v3-bluechip-weth-usdc")).toEqual({
      assetId: "uni-v3-stable:gho",
      marketId: "uni-v3-stable-usdc-usdt",
    })
  })

  it("keeps a venue-scoped asset on its OWN spoke's collateral market by default", () => {
    const session = {
      state: buildMockBorrowSystemState("demo-wallet"),
      marketSummaries: [
        { id: "uni-v3-bluechip-weth-usdc", name: "WETH / USDC", venue: "Uni v3 Bluechip", feeTier: "0.05%" },
        { id: "uni-v3-stable-usdc-usdt", name: "USDC / USDT", venue: "Uni v3 Stable", feeTier: "0.01%" },
      ],
      // Bluechip sorts first, so the old first-match default re-scoped the debt to it.
      collateralPools: [{ id: "uni-v3-bluechip-weth-usdc" }, { id: "uni-v3-stable-usdc-usdt" }],
      getBorrowableAssetsForMarket: () => [],
      borrowableAssets: [],
    }

    // No explicit market → stay on the asset's own spoke, not whichever pool sorts first.
    expect(resolveBorrowMarketForAsset(session as never, "uni-v3-stable:usdc", undefined)).toBe(
      "uni-v3-stable-usdc-usdt",
    )
    // An explicit different-venue choice is still honored (re-scopes on purpose).
    expect(resolveBorrowMarketForAsset(session as never, "uni-v3-stable:usdc", "uni-v3-bluechip-weth-usdc")).toBe(
      "uni-v3-bluechip-weth-usdc",
    )
  })
})

describe("claimSelectItemsForWallet", () => {
  it("shows positive claimable totals from reward positions", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const session = {
      state,
      collateralPools: [],
      getBorrowableAssetsForMarket: () => [],
      borrowableAssets: [],
    }

    const items = claimSelectItemsForWallet(session as never, "demo-wallet")
    expect(items.length).toBeGreaterThan(0)
    expect(items.some((item) => item.trailingLabel.includes("$111.10") || item.trailingLabel.includes("$111"))).toBe(
      true,
    )
    expect(items.every((item) => !item.trailingLabel.includes("$0.00"))).toBe(true)
  })

  it("hides claim rows when the wallet has no reward positions", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    state.accounts["demo-wallet"]!.rewardPositions = []

    const session = {
      state,
      collateralPools: [],
      getBorrowableAssetsForMarket: () => [],
      borrowableAssets: [],
    }

    expect(claimSelectItemsForWallet(session as never, "demo-wallet")).toHaveLength(0)
  })
})

describe("repaySelectItemsForWallet", () => {
  it("maps debt positions to select items", () => {
    const state = buildMockBorrowSystemState("wallet-1")
    const debt = state.accounts["wallet-1"]!.debtPositions[0]!
    debt.principalBorrowedUsd6 = parseFixed("1000", 6)
    debt.debtSharesUsd6 = parseFixed("1000", 6)
    debt.debtIndexRay = RAY + parseFixed("0.25", 27)

    const session = {
      state,
      collateralPools: [],
      getBorrowableAssetsForMarket: () => [],
      borrowableAssets: [],
    }

    const items = repaySelectItemsForWallet(session as never, "wallet-1")
    expect(items.length).toBeGreaterThan(0)
    expect(items.some((item) => item.symbol === "USDC")).toBe(true)
    expect(items.every((item) => item.trailingLabel.includes("owed"))).toBe(true)
  })
})

describe("lendWithdrawSelectItems", () => {
  it("maps active lend positions", () => {
    const session = {
      state: {
        positions: {
          p1: {
            walletId: "wallet-1",
            marketId: "gho",
            status: "active",
            currentSuppliedAmount: 12.5,
          },
        },
        markets: {
          gho: { asset: { name: "GHO Stablecoin", symbol: "GHO" } },
        },
      },
    }

    const items = lendWithdrawSelectItems(session as never, "wallet-1")
    expect(items[0]?.symbol).toBe("GHO")
    expect(items[0]?.trailingSublabel).toContain("supplied")
  })
})
