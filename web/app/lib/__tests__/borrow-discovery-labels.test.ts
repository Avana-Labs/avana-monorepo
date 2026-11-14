import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"
import { formatBorrowPairLabel, formatLtvPct, normalizeBorrowTokenSymbol } from "@/app/lib/borrow-market-rows"

const readSource = (relativeFromRepoRoot: string) =>
  readFileSync(resolve(__dirname, "../../..", relativeFromRepoRoot), "utf8")

describe("formatLtvPct (G2 — single LTV precision)", () => {
  it("keeps one decimal of precision, matching the collateral factor", () => {
    expect(formatLtvPct(79.5)).toBe("79.5%")
    expect(formatLtvPct(63.5)).toBe("63.5%")
  })

  it("trims a trailing .0 so whole-number factors read cleanly", () => {
    expect(formatLtvPct(80)).toBe("80%")
    expect(formatLtvPct(65)).toBe("65%")
    expect(formatLtvPct(78)).toBe("78%")
  })

  it("never rounds 79.5 up to 80 (the inconsistency the finding reports)", () => {
    expect(formatLtvPct(79.5)).not.toBe("80%")
  })
})

describe("normalizeBorrowTokenSymbol (G3 — WETH naming drift)", () => {
  it("canonicalizes native ETH to WETH", () => {
    expect(normalizeBorrowTokenSymbol("ETH")).toBe("WETH")
  })

  it("leaves WETH and ETH-suffixed LSTs untouched", () => {
    expect(normalizeBorrowTokenSymbol("WETH")).toBe("WETH")
    expect(normalizeBorrowTokenSymbol("stETH")).toBe("stETH")
    expect(normalizeBorrowTokenSymbol("wstETH")).toBe("wstETH")
    expect(normalizeBorrowTokenSymbol("weETH")).toBe("weETH")
    expect(normalizeBorrowTokenSymbol("USDC")).toBe("USDC")
  })
})

describe("formatBorrowPairLabel (G3 — normalized pair labels)", () => {
  it("normalizes ETH to WETH inside a pool name", () => {
    expect(formatBorrowPairLabel({ name: "WBTC / ETH" })).toBe("WBTC / WETH")
    expect(formatBorrowPairLabel({ name: "ETH / stETH" })).toBe("WETH / stETH")
  })

  it("preserves multi-token names so same-pair pools stay distinguishable", () => {
    expect(formatBorrowPairLabel({ name: "USDC / WBTC / ETH" })).toBe("USDC / WBTC / WETH")
  })

  it("leaves names without a plain ETH token unchanged", () => {
    expect(formatBorrowPairLabel({ name: "80/20 WETH/AAVE" })).toBe("80/20 WETH/AAVE")
    expect(formatBorrowPairLabel({ name: "waUSDC / USDC" })).toBe("waUSDC / USDC")
  })
})

describe("all borrow discovery surfaces route LTV through formatLtvPct (G2)", () => {
  it("Explore hero cards use the shared helper, not a raw ltv template", () => {
    const source = readSource("app/borrow/borrow-page-hero.tsx")
    expect(source).toContain("formatLtvPct(pool.ltv)")
    expect(source).not.toContain("${pool.ltv}% LTV")
  })

  it("collateral table (desktop CF + mobile Max LTV) use the shared helper", () => {
    const source = readSource("app/borrow/components/collateral-pools-table.tsx")
    expect(source).toContain("formatLtvPct(pool.ltv)")
    // Old, inconsistent renderers removed.
    expect(source).not.toContain("{Math.round(pool.ltv)}%")
    expect(source).not.toContain("`${pool.ltv}%`")
  })

  it("global search palette uses the shared helper", () => {
    const source = readSource("app/components/search-command.tsx")
    expect(source).toContain("formatLtvPct(pool.ltv)")
    expect(source).not.toContain("${pool.ltv}% LTV")
  })
})

describe("Explore cards lead with the pair label (G1)", () => {
  it("hero card title is the plain pair label, with no venue folded in or shown as a subtitle", () => {
    const source = readSource("app/borrow/borrow-page-hero.tsx")
    expect(source).toContain("title: formatBorrowPairLabel(pool)")
    // The curated Explore carousel dedupes by pool name, so it never features two
    // exact same-pair pools that would need a venue label to tell them apart.
    expect(source).not.toContain("pool.venue")
  })
})

describe("collateral rows disambiguate same-pair pools (G3)", () => {
  const source = readSource("app/borrow/components/collateral-pools-table.tsx")

  it("routes the pair label through formatBorrowPairLabel (WETH normalization + pool name)", () => {
    expect(source).toContain("formatBorrowPairLabel(pool)")
  })

  // The row sub-label is TVL / premium only, so the pair label alone must tell pools apart. If a
  // spoke ever lists the same pair twice (e.g. two fee tiers), bring the fee tier back into the row.
})
