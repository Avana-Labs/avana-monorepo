import { describe, expect, it } from "vitest"
import { blockedCtaLabel } from "@/app/lib/action-system/blocked-ui"

describe("blockedCtaLabel", () => {
  it("uses a {symbol} placeholder on insufficient-balance blocks", () => {
    // The ticker is interpolated at render (after translation), so the label is a key.
    expect(blockedCtaLabel("Insufficient wallet balance.", { symbol: "USDC" })).toEqual({
      label: "Insufficient {symbol}",
    })
    expect(blockedCtaLabel("You don't have enough balance to repay this amount.", { symbol: "ETH" })).toEqual({
      label: "Insufficient {symbol}",
    })
    // Without a symbol it falls back to a generic balance label.
    expect(blockedCtaLabel("Insufficient balance").label).toBe("Insufficient balance")
  })

  it("maps no-collateral to a disabled in-place label", () => {
    expect(blockedCtaLabel("You have no collateral in this market yet.")).toEqual({
      label: "No collateral",
    })
    expect(blockedCtaLabel("Deposit collateral before borrowing")).toEqual({
      label: "No collateral",
    })
  })

  it("maps missing multiply/deleverage positions to No position", () => {
    expect(blockedCtaLabel("No open position to deleverage in this market.").label).toBe("No position")
  })

  it("maps liquidity, borrowing power, and market-state blocks to short labels", () => {
    expect(blockedCtaLabel("There isn't enough liquidity for this amount right now.").label).toBe(
      "Insufficient liquidity",
    )
    expect(blockedCtaLabel("You don't have enough borrowing power for this amount.").label).toBe("Try a smaller amount")
    expect(blockedCtaLabel("Borrowing unavailable").label).toBe("Borrowing unavailable")
    expect(blockedCtaLabel("Market is paused.").label).toBe("Market paused")
    expect(blockedCtaLabel("Deposit would exceed the market supply cap.").label).toBe("Supply cap reached")
    expect(blockedCtaLabel("You don't have enough LP in your wallet for this deposit.").label).toBe("Insufficient LP")
  })

  it("handles claim and empty-amount reasons", () => {
    expect(blockedCtaLabel("Nothing to claim").label).toBe("Nothing to claim")
    expect(blockedCtaLabel("Select rewards to claim").label).toBe("Select rewards")
    expect(blockedCtaLabel("Amount must be positive.").label).toBe("Enter an amount")
  })

  it("uses state-specific labels for Umbrella cooldown blocks", () => {
    expect(blockedCtaLabel("Withdrawal window expired — restart cooldown.").label).toBe("Window expired")
    expect(blockedCtaLabel("Cooldown is not ready").label).toBe("Cooldown not ready")
    expect(blockedCtaLabel("Finish or unstake the current cooldown before starting a new one.").label).toBe(
      "Cooldown active",
    )
  })
})
