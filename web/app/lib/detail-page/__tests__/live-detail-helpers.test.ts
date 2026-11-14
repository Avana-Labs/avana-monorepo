import { describe, expect, it } from "vitest"
import {
  applyDetailContentOverlay,
  injectBaselinePrice,
  mergeAliasedQuickStats,
} from "@/app/lib/detail-page/live-detail-helpers"
import { formatTokenPrice } from "@/app/lib/prices/format"
import { sandboxBaselinePriceUsd } from "@/app/lib/prices/sandbox-baseline-prices"

describe("applyDetailContentOverlay", () => {
  const mockDetail = {
    about: {
      description: "Mock description",
      stats: [{ label: "Mock stat", value: "1" }],
      history: [{ date: "2024-01-01", title: "Mock history" }],
      governanceParameters: {
        parameters: [{ id: "collateralFactor", label: "Collateral factor", value: "75%" }],
        changelog: [{ date: "2024-01-02", parameter: "LTV", previous: "70%", current: "75%" }],
      },
    },
    faqs: [{ question: "Mock Q?", answer: "Mock A" }],
  }

  const convexContent = {
    description: "Convex description",
    stats: [{ label: "Convex stat", value: "2", href: "https://example.com" }],
    history: [{ date: "2026-01-01", title: "Convex history", description: "From seed" }],
    faqs: [{ question: "Convex Q?", answer: "Convex A" }],
  }

  it("applies Convex description, stats, history, and FAQs", () => {
    const next = applyDetailContentOverlay(mockDetail, convexContent)

    expect(next.about.description).toBe("Convex description")
    expect(next.about.stats).toEqual(convexContent.stats)
    expect(next.about.history).toEqual(convexContent.history)
    expect(next.faqs).toEqual(convexContent.faqs)
  })

  it("preserves governanceParameters from the base detail when content has no changelog", () => {
    const next = applyDetailContentOverlay(mockDetail, convexContent)

    expect(next.about.governanceParameters).toEqual(mockDetail.about.governanceParameters)
  })

  it("applies the Convex changelog when content carries one, keeping base parameters", () => {
    const changelog = [
      {
        id: "chg-0",
        parameter: "Supply cap",
        previous: "$100M",
        current: "$120M",
        date: "2026-05-01",
        source: "Risk parameter review",
        executor: "Governance executor",
        category: "Risk Management",
      },
    ]
    const next = applyDetailContentOverlay(mockDetail, { ...convexContent, changelog })

    expect(next.about.governanceParameters?.changelog).toEqual(changelog)
    // Base parameters are kept (applyRiskParametersToAbout refreshes them downstream).
    expect(next.about.governanceParameters?.parameters).toEqual(mockDetail.about.governanceParameters.parameters)
  })

  it("returns the base detail unchanged when content is null", () => {
    expect(applyDetailContentOverlay(mockDetail, null)).toBe(mockDetail)
    expect(applyDetailContentOverlay(mockDetail, undefined)).toBe(mockDetail)
  })

  it("clears catalog About/FAQs when content is missing and clearWhenMissing is set", () => {
    const next = applyDetailContentOverlay(mockDetail, null, { clearWhenMissing: true })
    expect(next.about.description).toBe("")
    expect(next.about.stats).toEqual([])
    expect(next.about.history).toEqual([])
    expect(next.faqs).toEqual([])
    // Fail closed in live: drop the mock changelog, but keep the parameter grid.
    expect(next.about.governanceParameters?.changelog).toEqual([])
    expect(next.about.governanceParameters?.parameters).toEqual(mockDetail.about.governanceParameters.parameters)
  })
})

describe("injectBaselinePrice", () => {
  it("pins the 'price' quick stat to the deterministic sandbox baseline (AAVE → $105.00)", () => {
    const base = [
      { id: "price", label: "Price", value: "$86.08" },
      { id: "available", label: "Available Liquidity", value: "$6M" },
    ]

    const next = injectBaselinePrice(base, "AAVE")

    expect(sandboxBaselinePriceUsd("AAVE")).toBe(105)
    expect(next.find((s) => s.id === "price")?.value).toBe("$105.00")
    expect(next.find((s) => s.id === "price")?.value).toBe(formatTokenPrice(sandboxBaselinePriceUsd("AAVE")))
  })

  it("does NOT let a live oracle value override the baseline", () => {
    // The overlay takes only the base stats + symbol — there is no live-price channel to
    // override the tile. Whatever the mock/catalog seeded, the tile becomes the baseline.
    const base = [{ id: "price", label: "Price", value: "$999999.99" }]

    const next = injectBaselinePrice(base, "AAVE")

    expect(next[0].value).toBe("$105.00")
  })

  it("leaves non-price stats untouched and resolves the symbol case-insensitively", () => {
    const base = [
      { id: "price", label: "Price", value: "x" },
      { id: "supplyApy", label: "Supply APY", value: "3.20%" },
    ]

    const next = injectBaselinePrice(base, "weth")

    expect(next.find((s) => s.id === "price")?.value).toBe(formatTokenPrice(sandboxBaselinePriceUsd("WETH")))
    expect(next.find((s) => s.id === "supplyApy")?.value).toBe("3.20%")
  })
})

describe("mergeAliasedQuickStats", () => {
  it("overlays Convex values onto aliased mock ids", () => {
    const base = [
      { id: "totalSupplied", value: "$1" },
      { id: "utilization", value: "10%" },
      { id: "reserveFactor", value: "5%" },
    ]
    const convex = [
      { id: "supplied", value: "$9M" },
      { id: "utilization", value: "42%" },
    ]

    const next = mergeAliasedQuickStats(base, convex, {
      supplied: ["supplied", "totalSupplied"],
      utilization: ["utilization"],
    })

    expect(next).toEqual([
      { id: "totalSupplied", value: "$9M" },
      { id: "utilization", value: "42%" },
      { id: "reserveFactor", value: "5%" },
    ])
  })
})
