import { describe, expect, it } from "vitest"
import { SandboxRewardsActionAdapter, buildDefaultRewardsSessionState } from "@/app/lib/rewards-system"
import { buildDefaultRewardsCatalog } from "@/app/lib/rewards-engine"

const now = Date.UTC(2026, 5, 19)
const wallet = "wallet-referral"

describe("referral reward tasks", () => {
  it("completes the sandbox referral loop", async () => {
    let state = buildDefaultRewardsSessionState()
    state.firstLoginAt = now
    const adapter = new SandboxRewardsActionAdapter({
      readState: () => state,
      writeState: (next) => {
        state = typeof next === "function" ? next(state) : next
      },
      now: () => now,
    })

    await adapter.initializeRewardsForWallet(wallet)
    await adapter.runReferralSandboxStep(wallet, "invite")

    const progressBeforeCopy = await adapter.refreshTaskProgress(wallet)
    expect(progressBeforeCopy.find((item) => item.taskId === "share-referral-link")?.status).not.toBe("claimable")

    await adapter.recordReferralLinkCopied(wallet)
    await adapter.runReferralSandboxStep(wallet, "activate")
    await adapter.runReferralSandboxStep(wallet, "fund")

    const progress = await adapter.refreshTaskProgress(wallet)
    expect(progress.find((item) => item.taskId === "share-referral-link")?.status).toBe("claimable")
    expect(progress.find((item) => item.taskId === "invite-first-wallet")?.status).toBe("claimable")
  })

  it("defines three referral quests", () => {
    expect(buildDefaultRewardsCatalog(now).filter((task) => task.category === "referral")).toHaveLength(3)
  })
})
