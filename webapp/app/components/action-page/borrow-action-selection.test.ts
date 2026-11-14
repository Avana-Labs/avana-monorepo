import { expect, it } from "vitest"
import { resolveClaimPositions, selectionsFromPositions } from "./borrow-action-selection"

it("keeps claim selection wallet and market scoped", () => {
  const session = {
    state: {
      accounts: {
        wallet: {
          rewardPositions: [
            { id: "a", marketId: "eth" },
            { id: "b", marketId: "usdc" },
          ],
        },
      },
    },
  } as never
  expect(resolveClaimPositions(session, "wallet", "eth").map((row) => row.id)).toEqual(["a"])
  expect(resolveClaimPositions(session, "wallet", "", "b").map((row) => row.id)).toEqual(["b"])
  expect(selectionsFromPositions([{ id: "a" }, { id: "b" }])).toEqual({ a: true, b: true })
})
