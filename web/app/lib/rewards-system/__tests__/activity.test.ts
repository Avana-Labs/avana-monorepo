import { describe, expect, it } from "vitest"
import { buildRewardsActivityHistory } from "../activity"
import type { RewardClaim, RewardTask } from "@/app/lib/rewards-engine"

const claim = (overrides: Partial<RewardClaim> = {}): RewardClaim => ({
  claimId: "wallet-1:boot:1000",
  wallet: "wallet-1",
  taskId: "boot",
  amount: 25,
  rewardSymbol: "AVA",
  status: "confirmed",
  syntheticTxHash: "0xabc",
  claimedAt: 1000,
  ...overrides,
})

const bootTask = { id: "boot", title: "Boot your sandbox wallet" } as RewardTask

describe("buildRewardsActivityHistory", () => {
  it("maps a claim to a rewards/claim activity row using the task title", () => {
    const [row] = buildRewardsActivityHistory("wallet-1", [claim()], [bootTask])
    expect(row).toMatchObject({
      id: "wallet-1:boot:1000",
      product: "rewards",
      kind: "claim",
      status: "confirmed",
      amountUsd: 25,
      primaryLabel: "Boot your sandbox wallet",
      secondaryLabel: "25 AVA claimed",
      txHash: "0xabc",
    })
    expect(row.at).toBe(new Date(1000).toISOString())
  })

  it("only returns claims for the given wallet", () => {
    const rows = buildRewardsActivityHistory(
      "wallet-1",
      [claim(), claim({ claimId: "other", wallet: "wallet-2" })],
      [bootTask],
    )
    expect(rows).toHaveLength(1)
    expect(rows[0].id).toBe("wallet-1:boot:1000")
  })

  it("falls back to a generic label when the task is unknown and maps pending status", () => {
    const [row] = buildRewardsActivityHistory("wallet-1", [claim({ taskId: "gone", status: "pending" })], [])
    expect(row.primaryLabel).toBe("Avana rewards")
    expect(row.status).toBe("pending")
  })
})
