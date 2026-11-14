import { describe, expect, it } from "vitest"
import {
  isConfigureVisibleStage,
  isProcessingStage,
  isSubmittingStage,
  primaryCtaLabel,
  reviewStageTitle,
  secondaryCtaLabel,
} from "@/app/lib/action-system/stage-machine"

describe("configure visibility", () => {
  it("shows the configure UI only for the configure and error stages", () => {
    expect(isConfigureVisibleStage("configure")).toBe(true)
    expect(isConfigureVisibleStage("error")).toBe(true)
    // Post-review signing stages hand the screen to the pending view, not the amount card.
    expect(isConfigureVisibleStage("approve_allowance")).toBe(false)
    expect(isConfigureVisibleStage("wallet_sign")).toBe(false)
    expect(isConfigureVisibleStage("review")).toBe(false)
    expect(isConfigureVisibleStage("processing")).toBe(false)
    expect(isConfigureVisibleStage("success")).toBe(false)
  })

  it("identifies every pending transaction lifecycle stage", () => {
    expect(isProcessingStage("processing")).toBe(true)
    expect(isProcessingStage("submitted")).toBe(true)
    expect(isProcessingStage("confirmed")).toBe(true)
    expect(isProcessingStage("refreshing_position")).toBe(true)
    expect(isProcessingStage("reconciled")).toBe(true)
    expect(isProcessingStage("success")).toBe(false)
  })

  it("treats signing and processing as submitting stages the amount card yields to", () => {
    // Signing stages join the processing lifecycle: the pending view owns the screen and
    // the editable amount card must not render, so the two predicates are mutually exclusive.
    for (const stage of ["approve_allowance", "wallet_sign"] as const) {
      expect(isSubmittingStage(stage)).toBe(true)
      expect(isConfigureVisibleStage(stage)).toBe(false)
    }
    expect(isSubmittingStage("processing")).toBe(true)
    expect(isSubmittingStage("reconciled")).toBe(true)
    expect(isSubmittingStage("configure")).toBe(false)
    expect(isSubmittingStage("review")).toBe(false)
    expect(isSubmittingStage("success")).toBe(false)
    expect(isSubmittingStage("error")).toBe(false)
  })
})

describe("primaryCtaLabel", () => {
  it("uses Review on configure when valid", () => {
    expect(
      primaryCtaLabel({
        stage: "configure",
        verb: "Borrow",
        blockedReason: null,
        isValid: true,
      }),
    ).toBe("Review")
  })

  it("uses verb on review stage", () => {
    expect(
      primaryCtaLabel({
        stage: "review",
        verb: "Borrow",
        blockedReason: null,
        isValid: true,
      }),
    ).toBe("Borrow")
  })

  it("turns a block into a short, in-place CTA label", () => {
    expect(
      primaryCtaLabel({
        stage: "configure",
        verb: "Borrow",
        blockedReason: "Insufficient balance",
        isValid: false,
      }),
    ).toBe("Insufficient balance")

    // With a symbol present the label is a {symbol} placeholder key — the ticker is
    // interpolated at render (after translation) so the label localizes.
    expect(
      primaryCtaLabel({
        stage: "configure",
        verb: "Deposit",
        blockedReason: "Insufficient wallet balance.",
        isValid: true,
        blockedSymbol: "USDC",
      }),
    ).toBe("Insufficient {symbol}")

    expect(
      primaryCtaLabel({
        stage: "configure",
        verb: "Borrow",
        blockedReason: "You have no collateral in this market yet.",
        isValid: false,
      }),
    ).toBe("No collateral")
  })

  it("shows validation label for invalid entered amounts", () => {
    expect(
      primaryCtaLabel({
        stage: "configure",
        verb: "Borrow",
        blockedReason: null,
        isValid: false,
        amountEntered: true,
      }),
    ).toBe("Enter a valid amount")
  })
})

describe("secondaryCtaLabel", () => {
  it("uses Back on review and configure when applicable", () => {
    expect(secondaryCtaLabel("review")).toBe("Back")
    expect(secondaryCtaLabel("configure", { canGoBack: true })).toBe("Back")
    expect(secondaryCtaLabel("configure", { canGoBack: false })).toBe("Cancel")
    expect(secondaryCtaLabel("success")).toBe("Done")
  })
})

describe("reviewStageTitle", () => {
  it("formats review titles from verbs", () => {
    expect(reviewStageTitle("Borrow")).toBe("Review borrow")
    expect(reviewStageTitle("Deposit")).toBe("Review deposit")
  })
})
