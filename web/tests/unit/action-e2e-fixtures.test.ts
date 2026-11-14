import { describe, expect, it } from "vitest"
import { actionFixturePaths, assertIsolatedStaging, walletFromAuthToken } from "../../scripts/action-e2e-fixtures.mjs"

function token(payload: object) {
  return `header.${Buffer.from(JSON.stringify(payload)).toString("base64url")}.signature`
}

describe("action E2E fixture preparation", () => {
  it("refuses missing opt-in, production, and malformed targets", () => {
    expect(() => assertIsolatedStaging({})).toThrow(/AVANA_E2E_STAGING/)
    expect(() =>
      assertIsolatedStaging({
        AVANA_E2E_STAGING: "1",
        AVANA_E2E_CONVEX_URL: "https://prod.convex.cloud",
        NEXT_PUBLIC_CONVEX_URL: "https://prod.convex.cloud",
      }),
    ).toThrow(/Refusing/)
    expect(() =>
      assertIsolatedStaging({
        AVANA_E2E_STAGING: "1",
        AVANA_E2E_CONVEX_URL: "https://example.com",
        NEXT_PUBLIC_CONVEX_URL: "https://prod.convex.cloud",
      }),
    ).toThrow(/Convex Cloud/)
  })

  it("extracts the authenticated wallet and rejects expired tokens", () => {
    expect(walletFromAuthToken(token({ wallet: "0xABC", exp: Math.floor(Date.now() / 1000) + 60 }))).toBe("0xabc")
    expect(() => walletFromAuthToken(token({ sub: "0xabc", exp: 1 }))).toThrow(/expired/)
  })

  it("derives funded, explicit borrow, multiply, and repay routes", () => {
    const paths = actionFixturePaths({
      borrow: [{ state: "collateral", marketId: "pool-a", assetId: undefined, amount: 100, valueUsd: 1000 }],
      multiply: [{ state: "position", marketId: "loop-a", assetId: "eth", amount: 1, valueUsd: 2000 }],
      liquid: [
        { state: "available", assetId: "eth", amount: 2, valueUsd: 4000 },
        { state: "available", assetId: "usdc", amount: 500, valueUsd: 500 },
      ],
    })

    expect(paths.AVANA_E2E_BORROW_PATH).toBe("/actions/borrow/borrow?market=pool-a&asset=usdc&amount=5")
    expect(paths.AVANA_E2E_MULTIPLY_PATH).toBe("/actions/multiply/multiply?market=loop-a&amount=0.005")
    expect(paths.AVANA_E2E_REPAY_PATH).toBe("/actions/borrow/repay?market=pool-a&asset=usdc&amount=5")
  })

  it("fails closed when no multiply position has matching spendable collateral", () => {
    expect(() =>
      actionFixturePaths({
        borrow: [{ state: "collateral", marketId: "pool-a", amount: 1, valueUsd: 1 }],
        multiply: [{ state: "position", marketId: "loop-a", assetId: "eth", amount: 1, valueUsd: 2000 }],
        liquid: [{ state: "available", assetId: "usdc", amount: 100, valueUsd: 100 }],
      }),
    ).toThrow(/matching liquid collateral/)
  })
})
