import { describe, expect, it } from "vitest"
import {
  mapConvexActivityItemsToRows,
  mergeActivityRows,
  type ConvexActivityItem,
} from "@/app/dashboard/convex-activity"
import type { PortfolioActivityRow } from "@/app/lib/data/providers/portfolio"
import { buildRewardsActivityHistory } from "@/app/lib/rewards-system"
import { rewardsClaimTxHash } from "@/app/lib/rewards-engine"
import type { RewardClaim } from "@/app/lib/rewards-engine"

function makeConvex(
  overrides: Partial<ConvexActivityItem> & Pick<ConvexActivityItem, "id" | "hash">,
): ConvexActivityItem {
  return {
    source: "transaction",
    product: "umbrella",
    kind: "stake",
    status: "success",
    amountUsd: 1000,
    marketSlug: "weth",
    at: Date.parse("2026-06-19T12:00:00.000Z"),
    ...overrides,
  }
}

describe("mapConvexActivityItemsToRows", () => {
  it("maps Convex activity into dashboard rows", () => {
    expect(mapConvexActivityItemsToRows([makeConvex({ id: "tx-1", hash: "sim-1" })])).toEqual([
      {
        id: "tx-1",
        at: "2026-06-19T12:00:00.000Z",
        product: "umbrella",
        kind: "stake",
        status: "confirmed",
        amountUsd: 1000,
        primaryLabel: "weth",
        secondaryLabel: "Stake",
        txHash: "sim-1",
        marketId: "weth",
      },
    ])
  })

  it("normalizes deposit/multiply/deleverage kinds", () => {
    const rows = mapConvexActivityItemsToRows([
      makeConvex({ id: "1", hash: "a", product: "lend", kind: "deposit" }),
      makeConvex({ id: "2", hash: "b", product: "multiply", kind: "multiply" }),
      makeConvex({ id: "3", hash: "c", product: "multiply", kind: "deleverage" }),
    ])
    expect(rows.map((row) => row.kind)).toEqual(["supply", "open", "reduce"])
  })

  it("labels Multiply activity with its market and collateral asset", () => {
    const [row] = mapConvexActivityItemsToRows([
      makeConvex({
        id: "multiply-close",
        hash: "sim-multiply-close",
        product: "multiply",
        kind: "close",
        marketSlug: "wsteth-eth",
      }),
    ])

    expect(row).toMatchObject({
      product: "multiply",
      kind: "close",
      primaryLabel: "Close position",
      secondaryLabel: "wstETH / ETH",
      marketId: "wsteth-eth",
    })
  })

  it("maps persisted onboarding grants to received sandbox funds", () => {
    const rows = mapConvexActivityItemsToRows([
      makeConvex({
        source: "sandboxActivity",
        id: "asset-grant",
        hash: "sim-onboarding-asset",
        product: "onboarding",
        kind: "starterAssetGrant",
        marketSlug: "usdc",
        amountUsd: 25_000,
      }),
      makeConvex({
        source: "sandboxActivity",
        id: "claim",
        hash: "sim-onboarding",
        product: "onboarding",
        kind: "onboardingClaim",
        marketSlug: null,
        amountUsd: 1_000_000,
      }),
    ])

    expect(rows).toEqual([
      expect.objectContaining({
        product: "onboarding",
        kind: "claim",
        primaryLabel: "USDC sandbox funds",
        secondaryLabel: "Sandbox funds received",
        amountUsd: 25_000,
        marketId: "usdc",
      }),
      expect.objectContaining({
        product: "onboarding",
        kind: "claim",
        primaryLabel: "Sandbox portfolio funded",
        secondaryLabel: "Onboarding grant",
        amountUsd: 1_000_000,
      }),
    ])
  })

  it("normalizes legacy Umbrella sandbox activity kinds", () => {
    const [row] = mapConvexActivityItemsToRows([
      makeConvex({
        source: "sandboxActivity",
        id: "activity-copy",
        hash: "sim-umbrella-stake-weth",
        product: "onboarding",
        kind: "umbrella_stake",
      }),
    ])
    expect(row).toMatchObject({ product: "umbrella", kind: "stake", marketId: "weth" })
  })
})

describe("mergeActivityRows", () => {
  it("keeps distinct rows that share a tx hash and prefers seed labels", () => {
    const seed: PortfolioActivityRow[] = [
      {
        id: "seed-weth",
        at: "2026-06-19T12:00:00.000Z",
        product: "umbrella",
        kind: "stake",
        status: "confirmed",
        amountUsd: 6700,
        primaryLabel: "Staked WETH",
        secondaryLabel: "3.4747 WETH",
        txHash: "sim-shared",
        marketId: "weth",
      },
    ]
    const convex = mapConvexActivityItemsToRows([
      makeConvex({ id: "seed-weth", hash: "sim-shared", marketSlug: "weth", amountUsd: 6700 }),
      makeConvex({ id: "convex-usdc", hash: "sim-shared", marketSlug: "usdc", amountUsd: 8000 }),
    ])

    const merged = mergeActivityRows(seed, convex)
    expect(merged).toHaveLength(2)
    expect(merged.find((row) => row.id === "seed-weth")?.primaryLabel).toBe("Staked WETH")
    expect(merged.find((row) => row.id === "convex-usdc")?.primaryLabel).toBe("usdc")
  })

  it("collapses cross-store copies but preserves same-hash actions for other markets", () => {
    const seed: PortfolioActivityRow[] = [
      {
        id: "session-weth",
        at: "2026-06-19T12:00:00.000Z",
        product: "umbrella",
        kind: "stake",
        status: "confirmed",
        amountUsd: 6700,
        primaryLabel: "Staked WETH",
        secondaryLabel: "3.4747 WETH",
        txHash: "sim-shared",
        marketId: "weth",
      },
    ]
    const convex = mapConvexActivityItemsToRows([
      makeConvex({ id: "durable-weth", hash: "sim-shared", marketSlug: "weth", amountUsd: 6700 }),
      makeConvex({ id: "durable-usdc", hash: "sim-shared", marketSlug: "usdc", amountUsd: 8000 }),
    ])

    const merged = mergeActivityRows(seed, convex)
    expect(merged.map((row) => row.id).sort()).toEqual(["durable-usdc", "session-weth"])
  })

  it("collapses a rewards claim into its quest-titled seed row (no 'Avana rewards' duplicate)", () => {
    const wallet = "0xabc"
    const taskId = "first-lend-deposit"
    // The engine now stamps the seed claim with the shared rewardsClaimTxHash; the
    // durable Convex write uses the same value, so the two records must dedup.
    const claim: RewardClaim = {
      claimId: `${wallet}:${taskId}:1`,
      wallet,
      taskId,
      amount: 100,
      rewardSymbol: "AVA",
      status: "confirmed",
      syntheticTxHash: rewardsClaimTxHash([taskId]),
      claimedAt: Date.parse("2026-06-19T12:00:00.000Z"),
    }
    const seed = buildRewardsActivityHistory(
      wallet,
      [claim],
      [{ id: taskId, title: "Lend $500 in the sandbox" } as never],
    )
    // The generic rewards row getActivity returns for the same claim: no marketSlug,
    // so it would otherwise render as "Avana rewards" / "Claim · Claim".
    const convex = mapConvexActivityItemsToRows([
      {
        id: "durable-rewards",
        source: "transaction",
        product: "rewards",
        kind: "claim",
        status: "success",
        amountUsd: 100,
        marketSlug: undefined,
        at: claim.claimedAt,
        hash: rewardsClaimTxHash([taskId]),
      },
    ])
    expect(convex[0]?.primaryLabel).toBe("Avana rewards") // fallback confirmed

    const merged = mergeActivityRows(seed, convex)
    expect(merged).toHaveLength(1)
    expect(merged[0]?.primaryLabel).toBe("Lend $500 in the sandbox")
    expect(merged[0]?.secondaryLabel).toBe("100 AVA claimed")
  })
})
