import { describe, expect, it } from "vitest"
import { translate } from "@/app/lib/i18n/translations"

const ONBOARDING_LANGS = ["ZH", "ES", "AR", "DE", "HI", "TR", "NL", "FR", "ID", "JA", "KO", "PT", "RU"] as const

describe("action translations", () => {
  it("translates generated success and receipt copy", () => {
    expect(translate("ES", "Deposit successful")).toBe("Depósito completado")
    expect(translate("ES", "12.0000 EURC processed.")).toBe("12.0000 EURC procesado.")
    expect(translate("FR", "Receipt")).toBe("Reçu")
    expect(translate("JA", "Deposit successful")).toBe("預け入れ 成功")
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
