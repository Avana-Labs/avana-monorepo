import { describe, expect, it } from "vitest"
import { SandboxRewardsActionAdapter } from "../sandbox-action-adapter"
import { buildDefaultRewardsSessionState } from "../storage"
import type { RewardsSessionState } from "../contracts"

const WALLET_A = "0xAAaA000000000000000000000000000000001111"
const WALLET_B = "0xBBbB000000000000000000000000000000002222"

/** A wallet-scoped adapter whose state lives in a single mutable holder (mirrors the hook). */
function makeAdapter() {
  let state: RewardsSessionState = buildDefaultRewardsSessionState()
  const adapter = new SandboxRewardsActionAdapter({
    readState: () => state,
    writeState: (next) => {
      state = typeof next === "function" ? next(state) : next
    },
    now: () => 1000,
  })
  return { adapter, get: () => state }
}

/** The invite code wallet A actually hands out (minted in A's own isolated session). */
async function codeFor(wallet: string) {
  const { adapter, get } = makeAdapter()
  await adapter.initializeRewardsForWallet(wallet)
  const code = get().referralProfiles[wallet]?.referralCode
  if (!code) throw new Error("expected a referral code")
  return code
}

describe("applyReferralCode — cross-wallet resolution", () => {
  it("records a referral from another wallet's code without scanning the referred session", async () => {
    const codeA = await codeFor(WALLET_A)

    // B's session only ever contains B — the referrer A's profile is NOT here.
    const { adapter, get } = makeAdapter()
    await adapter.initializeRewardsForWallet(WALLET_B)

    const relationship = await adapter.applyReferralCode(WALLET_B, codeA)

    expect(relationship.referredWallet).toBe(WALLET_B)
    expect(relationship.referrerWallet).toBe(codeA)
    expect(get().relationships).toHaveLength(1)
    // The referred wallet records who referred it on its OWN profile.
    expect(get().referralProfiles[WALLET_B]?.referredBy).toBe(codeA)
  })

  it("accepts a lowercased code from the URL (normalizes case)", async () => {
    const codeA = await codeFor(WALLET_A)
    const { adapter } = makeAdapter()
    await adapter.initializeRewardsForWallet(WALLET_B)

    const relationship = await adapter.applyReferralCode(WALLET_B, codeA.toLowerCase())
    expect(relationship.referrerWallet).toBe(codeA)
  })

  it("is idempotent — a wallet keeps the first referrer that claimed it", async () => {
    const codeA = await codeFor(WALLET_A)
    const codeC = await codeFor("0xCCcC000000000000000000000000000000003333")
    const { adapter, get } = makeAdapter()
    await adapter.initializeRewardsForWallet(WALLET_B)

    const first = await adapter.applyReferralCode(WALLET_B, codeA)
    const second = await adapter.applyReferralCode(WALLET_B, codeC)

    expect(second).toEqual(first)
    expect(get().relationships).toHaveLength(1)
    expect(get().referralProfiles[WALLET_B]?.referredBy).toBe(codeA)
  })

  it("rejects a wallet referring itself", async () => {
    const { adapter } = makeAdapter()
    await adapter.initializeRewardsForWallet(WALLET_B)
    const ownCode = await codeFor(WALLET_B)

    await expect(adapter.applyReferralCode(WALLET_B, ownCode)).rejects.toThrow(/cannot refer itself/i)
  })

  it("rejects a malformed referral code", async () => {
    const { adapter } = makeAdapter()
    await adapter.initializeRewardsForWallet(WALLET_B)

    await expect(adapter.applyReferralCode(WALLET_B, "not-a-code")).rejects.toThrow(/invalid referral code/i)
  })
})
