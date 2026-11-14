import { describe, expect, it } from "vitest"
import { translate } from "@/app/lib/i18n/translations"

const ONBOARDING_LANGS = ["ZH", "ES", "AR", "DE", "HI", "TR", "NL", "FR", "ID", "JA", "KO", "PT", "RU"] as const

describe("onboarding translations", () => {
  it("translates the onboarding introduction", () => {
    expect(translate("ES", "Welcome to the Avana Sandbox")).not.toBe("Welcome to the Avana Sandbox")
    expect(translate("ES", "Unlimited practice funds")).toBe("Fondos de práctica ilimitados")
    expect(translate("FR", "No real assets involved")).not.toBe("No real assets involved")
  })

  it.each(ONBOARDING_LANGS)("translates the current onboarding strings in %s", (language) => {
    // Current onboarding copy (post dollar-figure removal). Excludes product-name/loanword
    // exceptions kept in English by design ("Multiply"; "Wallet"/"Lending" in DE/NL).
    const keys = [
      "Welcome to the Avana Sandbox",
      "Unlimited practice funds",
      "No transactions to sign",
      "No real assets involved",
      "Get started",
      "Connect an EVM wallet.",
      "Nice, your wallet's connected.",
      "Now let's make Avana yours.",
      "What should we call you?",
      "Appearance",
      "Almost done.",
      "Which DEXs do you use the most?",
      "Select all that apply",
      "Last step.",
      "Let's fund your sandbox.",
      "Fund my sandbox",
      "Good news, you're in.",
      "sandbox seats already claimed.",
      "Continue to allocation",
      "Share on X first",
      "I posted it",
      "Your sandbox is live.",
      "Everything's funded and waiting. Dive in whenever you're ready.",
      "Open dashboard",
    ]

    for (const key of keys) {
      expect(translate(language, key)).not.toBe(key)
    }
  })
})

describe("action translations", () => {
  it("translates generated success and receipt copy", () => {
    expect(translate("ES", "Deposit successful")).toBe("Depósito completado")
    expect(translate("ES", "12.0000 EURC processed.")).toBe("12.0000 EURC procesado.")
    expect(translate("FR", "Receipt")).toBe("Reçu")
    expect(translate("JA", "Multiply successful")).toBe("マルチプライ 成功")
  })
})

describe("action CTA gate labels", () => {
  const CTA_KEYS = [
    "Insufficient {symbol}",
    "Insufficient balance",
    "Insufficient liquidity",
    "Insufficient LP",
    "No collateral",
    "No position",
    "Borrowing unavailable",
    "Try a smaller amount",
    "Supply cap reached",
    "Market paused",
    "Price unavailable",
    "Not available here",
    "Nothing to claim",
    "Select rewards",
    "Nothing to withdraw",
  ]

  it.each(ONBOARDING_LANGS)("localizes every blocked-CTA label in %s", (language) => {
    for (const key of CTA_KEYS) {
      expect(translate(language, key)).not.toBe(key)
    }
  })

  it("keeps the {symbol} placeholder intact for interpolation", () => {
    expect(translate("ES", "Insufficient {symbol}")).toContain("{symbol}")
    expect(translate("JA", "Insufficient {symbol}")).toContain("{symbol}")
    expect(translate("RU", "Insufficient {symbol}")).toContain("{symbol}")
  })
})
