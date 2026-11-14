import { describe, expect, it } from "vitest"
import { actionErrorMessage, humanizeBlockedReason } from "@/app/lib/action-system/blocked-reason"

describe("humanizeBlockedReason", () => {
  it("maps 'available credit in spoke' to plain copy without the spoke id", () => {
    const out = humanizeBlockedReason("Wallet wallet-1 does not have enough available credit in spoke uni-v3-bluechip")
    expect(out).toBe("You don't have enough borrowing power for this amount. Lower the amount or add collateral.")
    expect(out).not.toMatch(/spoke|wallet-1|insolvent/i)
  })

  it("maps borrow insolvency without leaking 'insolvent' or 'spoke'", () => {
    const out = humanizeBlockedReason("Borrowing would make spoke uni-v3-bluechip insolvent")
    expect(out).toBe("This borrow is more than this market can safely support. Try a smaller amount.")
    expect(out).not.toMatch(/spoke|insolvent/i)
  })

  it("maps wallet-insolvency removal to a risk message", () => {
    const out = humanizeBlockedReason("Removing collateral would make wallet wallet-1 insolvent")
    expect(out).toBe("Removing this much collateral would put your position at risk. Lower the amount.")
    expect(out).not.toMatch(/wallet-1|insolvent/i)
  })

  it("maps spoke-insolvency removal without leaking internals", () => {
    const out = humanizeBlockedReason("Removing collateral would make spoke uni-v3-bluechip insolvent")
    expect(out).toBe("This removal is more than this market can safely support. Try a smaller amount.")
    expect(out).not.toMatch(/spoke|insolvent/i)
  })

  it("scrubs an unmapped message that still leaks a wallet id or spoke", () => {
    expect(humanizeBlockedReason("Wallet wallet-1 has no debt to liquidate")).not.toMatch(/wallet-1/i)
    expect(humanizeBlockedReason("Debt position d-1 does not belong to spoke uni-v3")).not.toMatch(/spoke/i)
  })

  it("scrubs a raw wallet address", () => {
    expect(humanizeBlockedReason("0xabc123def456 has no collateral in spoke x")).not.toMatch(/0xabc123def456/)
  })

  it("maps backend auth/rate-limit codes to plain copy (issue #143)", () => {
    const unauth = humanizeBlockedReason("UNAUTHENTICATED: connect a wallet and sign in to use the sandbox.")
    expect(unauth).toBe("Your session has expired. Reconnect your wallet and sign in to continue.")
    expect(unauth).not.toMatch(/UNAUTHENTICATED/)

    const mismatch = humanizeBlockedReason("WALLET_MISMATCH: cannot read or mutate a wallet you do not control.")
    expect(mismatch).toBe("This action doesn't match your connected wallet. Reconnect the right wallet and try again.")
    expect(mismatch).not.toMatch(/WALLET_MISMATCH/)

    const rate = humanizeBlockedReason("RATE_LIMITED: more than 60 sandbox transactions in the last hour.")
    expect(rate).toBe("You're doing that a bit too fast. Wait a moment and try again.")
    expect(rate).not.toMatch(/RATE_LIMITED/)
  })

  it("scrubs any unmapped raw backend code prefix (issue #143)", () => {
    const out = humanizeBlockedReason("INVALID_TRANSITION: executed amount exceeds the requested amount.")
    expect(out).not.toMatch(/INVALID_TRANSITION/)
    expect(humanizeBlockedReason("NO_PROFILE: start onboarding before claiming.")).not.toMatch(/NO_PROFILE/)
  })

  it("passes through already-friendly copy unchanged", () => {
    const friendly = "Enter an amount to continue."
    expect(humanizeBlockedReason(friendly)).toBe(friendly)
  })

  it("returns null for empty input", () => {
    expect(humanizeBlockedReason(null)).toBeNull()
    expect(humanizeBlockedReason(undefined)).toBeNull()
  })
})

// Prod 2026-09-23: a failed borrow showed "[CONVEX M(sandbox/transactions:recordTransaction)]
// [Request ID: 14e5d54127067663] Server Error Called by client" on the action page.
describe("actionErrorMessage", () => {
  it("never shows the raw Convex failure string", () => {
    const error = new Error(
      "[CONVEX M(sandbox/transactions:recordTransaction)] [Request ID: 14e5d54127067663] Server Error Called by client",
    )
    const out = actionErrorMessage(error, "Transaction was cancelled")
    expect(out).not.toMatch(/CONVEX|Request ID|Server Error/)
    expect(out).toMatch(/nothing was changed/)
  })

  it("maps the ConvexError code in error.data to plain copy", () => {
    const error = Object.assign(new Error("[CONVEX M(x)] Server Error"), {
      data: { code: "INSUFFICIENT_BALANCE", message: "INSUFFICIENT_BALANCE: withdraw exceeds the deposited amount." },
    })
    expect(actionErrorMessage(error, "fallback")).toBe(
      "You don't have enough balance for this amount. Lower the amount.",
    )
  })

  it("maps a stale write to a reload hint", () => {
    const error = Object.assign(new Error("x"), { data: { code: "STALE_WRITE", message: "STALE_WRITE: changed" } })
    expect(actionErrorMessage(error, "fallback")).toMatch(/Reload the page/)
  })

  it("keeps the fallback for a non-error value", () => {
    expect(actionErrorMessage(undefined, "Swap failed.")).toBe("Swap failed.")
  })
})
