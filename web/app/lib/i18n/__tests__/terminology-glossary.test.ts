import { describe, expect, it } from "vitest"
import { translate } from "@/app/lib/i18n/translations"

/**
 * Terminology + UI-fit guards for product/chrome labels.
 *
 * Action tabs (Stake / Claim / Cooldown / Unstake) must stay short — long
 * dictionary literals (FR "Refroidissement", "Réclamation") blow up the sidebar.
 * Admin-panel literals remain forbidden.
 */

const FORBIDDEN_LONG_TAB_LABELS: Record<string, Partial<Record<"Claim" | "Cooldown" | "Unstake", string[]>>> = {
  FR: {
    Claim: ["Réclamation"],
    Cooldown: ["Refroidissement"],
    Unstake: ["Débloquer"],
  },
  ES: {
    Claim: ["Reclamo"],
    Cooldown: ["Enfriamiento"],
  },
  PT: {
    Cooldown: ["Resfriamento"],
  },
  DE: {
    Claim: ["Beanspruchen"],
    Cooldown: ["Abkühlung"],
  },
  NL: {
    Cooldown: ["Afkoelperiode"],
  },
  AR: {
    Cooldown: ["فترة التبريد"],
    Unstake: ["إلغاء التجميد"],
  },
  TR: {
    Cooldown: ["Bekleme süresi"],
    Unstake: ["Kilidi aç"],
  },
  ZH: {
    Unstake: ["解除质押"],
  },
}

describe("terminology: Dashboard is not admin-panel English/bureaucracy", () => {
  it("FR is not Tableau de bord", () => {
    expect(translate("FR", "Dashboard")).not.toBe("Tableau de bord")
    expect(translate("FR", "Dashboard")).not.toBe("Dashboard")
  })
  it("ZH is not 仪表盘", () => {
    expect(translate("ZH", "Dashboard")).not.toBe("仪表盘")
    expect(translate("ZH", "Dashboard")).not.toBe("Dashboard")
  })
})

describe("terminology: Wallet ≠ Portfolio", () => {
  it("FR and AR", () => {
    for (const lang of ["FR", "AR"] as const) {
      expect(translate(lang, "Wallet")).not.toBe(translate(lang, "Portfolio"))
    }
  })
})

describe("UI fit: action tabs stay short", () => {
  const langs = ["FR", "ES", "PT", "DE", "NL", "RU", "ID", "TR", "AR", "ZH", "JA", "KO", "HI"] as const
  const tabKeys = ["Stake", "Claim", "Cooldown", "Unstake"] as const

  it.each(langs)("%s tab labels are short enough for the sidebar", (lang) => {
    for (const key of tabKeys) {
      const value = translate(lang, key)
      // CJK glyphs are wide; allow a slightly higher code-unit budget there.
      const max = lang === "JA" || lang === "KO" || lang === "ZH" || lang === "HI" || lang === "AR" ? 12 : 10
      expect(value.length, `${lang} ${key}="${value}"`).toBeLessThanOrEqual(max)
      expect(value.length).toBeGreaterThan(0)
    }
  })

  it.each(Object.entries(FORBIDDEN_LONG_TAB_LABELS))("%s rejects known layout-breaking literals", (lang, byKey) => {
    for (const [key, forbidden] of Object.entries(byKey)) {
      const value = translate(lang as never, key)
      for (const word of forbidden ?? []) expect(value).not.toBe(word)
    }
  })
})

describe("CTA copy exists for stake flow", () => {
  const langs = ["FR", "ES", "PT", "DE", "JA", "ZH"] as const
  it.each(langs)("%s localizes Stake more + Enter an amount", (lang) => {
    expect(translate(lang, "Stake more")).not.toBe("Stake more")
    expect(translate(lang, "Enter an amount")).not.toBe("Enter an amount")
  })
})
