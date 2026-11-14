import { describe, expect, it } from "vitest"
import { resolveBorrowAssetId, resolveBorrowMarketForAsset } from "@/app/lib/action-system/resolve-borrow-context"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { listSpokeBorrowables } from "@/app/lib/borrow-system/registry"
import { selectBorrowMarketSummaries, selectBorrowableAssets } from "@/app/lib/borrow-system/selectors"
import { selectHomeBorrowTokensForMarket } from "@/app/lib/borrow-system/home-runtime"

describe("bal-stable:gho asset resolution", () => {
  it("resolves bal-stable:gho onto a Balancer Stable market with GHO in the token list", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const gho = listSpokeBorrowables().find((asset) => asset.id === "bal-stable:gho")
    expect(gho).toBeTruthy()
    const preferred = gho!.marketIds[0]!
    const market = state.markets[preferred]!
    const tokens = selectHomeBorrowTokensForMarket(state, "demo-wallet", preferred)

    expect(market.spokeId).toBe("bal-stable")
    expect(market.relations.supportedBorrowAssetIds).toContain("bal-stable:gho")
    expect(resolveBorrowAssetId(state, "bal-stable:gho", preferred)).toBe("bal-stable:gho")
    expect(tokens.some((token) => token.id === "bal-stable:gho" && token.symbol === "GHO")).toBe(true)

    const session = {
      state,
      marketSummaries: selectBorrowMarketSummaries(state, "demo-wallet"),
      collateralPools: [],
      getBorrowableAssetsForMarket: (marketId?: string) => selectBorrowableAssets(state, "demo-wallet", marketId),
      borrowableAssets: selectBorrowableAssets(state, "demo-wallet"),
    }
    expect(resolveBorrowMarketForAsset(session, "bal-stable:gho", preferred)).toBe(preferred)
  })
})
