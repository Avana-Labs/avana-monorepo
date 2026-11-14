import { describe, expect, it } from "vitest"
import { mapConvexActivityItemsToRows } from "@/app/dashboard/convex-activity"

// Prod 2026-09-23: the same claim read "Repay a sandbox loan · 25 AVA claimed" or
// "Avana rewards · Claim · Claim" depending on whether the rewards session had loaded.
describe("mapConvexActivityItemsToRows rewards claims", () => {
  it("titles a claim from its task and states the AVA amount", () => {
    const [row] = mapConvexActivityItemsToRows([
      {
        source: "transaction",
        id: "t1",
        product: "rewards",
        kind: "claim",
        status: "success",
        amountUsd: 25,
        marketSlug: null,
        claimedTaskIds: ["connect-wallet"],
        hash: "sim-rewards-claim-1",
        at: 1,
      },
    ])
    expect(row?.primaryLabel).toBe("Boot your sandbox wallet")
    expect(row?.secondaryLabel).toBe("25 AVA claimed")
  })
})
