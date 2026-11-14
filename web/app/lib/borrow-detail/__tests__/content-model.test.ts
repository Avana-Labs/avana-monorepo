import { describe, expect, it } from "vitest"
import {
  buildAssetFaqs,
  buildLendFaqs,
  buildMultiplyAboutDescription,
  buildMultiplyFaqs,
  buildPoolFaqs,
} from "@/app/lib/borrow-detail/content-model"

describe("detail page FAQs", () => {
  it("ships five important questions on every product detail page", () => {
    const asset = buildAssetFaqs("GHO", "GHO")
    const lend = buildLendFaqs("USDC", "USD Coin")
    const multiply = buildMultiplyFaqs("AAVE", "GHO")
    const pool = buildPoolFaqs("WETH / USDC")

    for (const faqs of [asset, lend, multiply, pool]) {
      expect(faqs).toHaveLength(5)
      expect(new Set(faqs.map((faq) => faq.question)).size).toBe(5)
      expect(faqs.every((faq) => faq.question.length > 8 && faq.answer.length > 40)).toBe(true)
    }
  })

  it("templates multiply answers with the pair", () => {
    const faqs = buildMultiplyFaqs("AAVE", "GHO")
    expect(faqs[0]?.question).toContain("AAVE / GHO")
    expect(faqs[1]?.answer).toContain("AAVE")
    expect(faqs[1]?.answer).toContain("GHO")
    expect(faqs[3]?.answer).toContain("AAVE")
  })

  it("writes a lend-length About for multiply markets", () => {
    const description = buildMultiplyAboutDescription({
      collateralName: "Aave",
      collateralSymbol: "AAVE",
      borrowName: "GHO",
      borrowSymbol: "GHO",
      maxLeverage: "1.80x",
      riskTier: "high",
    })
    expect(description.length).toBeGreaterThan(280)
    expect(description).toContain("Aave (AAVE) / GHO (GHO)")
    expect(description).toContain("1.80x")
    expect(description).toContain("tier-high")
  })
})
