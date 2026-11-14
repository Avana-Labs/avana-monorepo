import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

/**
 * p1-11: every Convex session writer must be gated on the product runtime scope that
 * owns its query. Otherwise a skipped subscription (remote forced to null/[]) plus an
 * always-on persist callback recreates the rewards saveState REVISION_REQUIRED loop.
 */
describe("scope-gated Convex session persists", () => {
  const source = readFileSync(resolve(__dirname, "../convex-avana-sessions-provider.tsx"), "utf8")

  it("p1-11: gates borrow/lend/multiply persists on walletSession", () => {
    expect(source).toMatch(/persistBorrowTransaction=\{scope\.walletSession \? persistBorrowTransaction : undefined\}/)
    expect(source).toMatch(/persistLendTransaction=\{scope\.walletSession \? persistLendTransaction : undefined\}/)
    expect(source).toMatch(
      /persistMultiplyTransaction=\{scope\.walletSession \? persistMultiplyTransaction : undefined\}/,
    )
  })

  it("p1-11: gates swap persist + quote on swapTransactions", () => {
    expect(source).toMatch(/persistSwapTransaction=\{scope\.swapTransactions \? persistSwapTransaction : undefined\}/)
    expect(source).toMatch(/serverGetSwapQuote=\{scope\.swapTransactions \? serverGetSwapQuote : undefined\}/)
  })

  it("p1-11: gates rewards + umbrella persists on their scopes", () => {
    expect(source).toMatch(/persistRewardsState=\{scope\.rewards \? persistRewardsState : undefined\}/)
    expect(source).toMatch(/persistUmbrellaAction=\{scope\.umbrella \? persistUmbrellaAction : undefined\}/)
  })
})
