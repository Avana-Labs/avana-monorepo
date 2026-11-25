import { describe, expect, it } from "vitest"
import {
  lpTokenPriceUsd,
  normalizeWeights,
  suppliedUsd,
  type WeightedConstituent,
} from "@/app/lib/prices/lp-token-price"

/**
 * Demonstration FIXTURE prices only (not production values). These pin the required Avana
 * LP-collateral accounting examples from the spec.
 */
const FIXTURE: Record<string, number> = {
  ETH: 1900,
  WBTC: 64000,
  USDC: 1.0,
  USDT: 0.999,
  DAI: 1.001,
  GHO: 0.998,
  LDO: 1.2,
  LINK: 14,
  AAVE: 180,
  UNI: 7.5,
}
const priceOf = (s: string) => FIXTURE[s]

/** Author weights as small integers; normalize to fractions summing to 1. */
const weighted = (...items: [string, number][]): WeightedConstituent[] =>
  normalizeWeights(items.map(([symbol, weight]) => ({ symbol, weight })))

const equal = (...symbols: string[]): WeightedConstituent[] =>
  normalizeWeights(symbols.map((symbol) => ({ symbol, weight: 1 })))

function priceOrThrow(constituents: WeightedConstituent[], p = priceOf): number {
  const r = lpTokenPriceUsd(constituents, p)
  if (!r.ok) throw new Error(`unexpected unavailable: ${r.reason} ${r.detail ?? ""}`)
  return r.priceUsd
}

describe("lpTokenPriceUsd — Σ(weightᵢ × priceᵢ)", () => {
  it("stable pair USDC/USDT 50/50 = $0.9995 and 12,000 LP = $11,994", () => {
    const lp = priceOrThrow(weighted(["USDC", 1], ["USDT", 1]))
    expect(lp).toBeCloseTo(0.9995, 9)
    expect(suppliedUsd(12_000, lp)).toBeCloseTo(11_994, 6)
  })

  it("volatile pair ETH/USDC 50/50 = $950.50", () => {
    expect(priceOrThrow(weighted(["ETH", 1], ["USDC", 1]))).toBeCloseTo(950.5, 9)
  })

  it("3 assets equal-weight ETH/GHO/WBTC = (ETH+GHO+WBTC)/3", () => {
    const lp = priceOrThrow(equal("ETH", "GHO", "WBTC"))
    expect(lp).toBeCloseTo((1900 + 0.998 + 64000) / 3, 6)
  })

  it("weighted ETH/LDO/GHO 50/25/25 = 0.50·ETH + 0.25·LDO + 0.25·GHO", () => {
    const lp = priceOrThrow(weighted(["ETH", 2], ["LDO", 1], ["GHO", 1]))
    expect(lp).toBeCloseTo(0.5 * 1900 + 0.25 * 1.2 + 0.25 * 0.998, 9)
    expect(lp).toBeCloseTo(950.5495, 6)
  })

  it("4-token equal-weight ETH/DAI/GHO/WBTC = (…)/4", () => {
    const lp = priceOrThrow(equal("ETH", "DAI", "GHO", "WBTC"))
    expect(lp).toBeCloseTo((1900 + 1.001 + 0.998 + 64000) / 4, 6)
  })

  it("weighted WBTC/USDC/USDT 20/40/40", () => {
    const lp = priceOrThrow(weighted(["WBTC", 1], ["USDC", 2], ["USDT", 2]))
    expect(lp).toBeCloseTo(0.2 * 64000 + 0.4 * 1 + 0.4 * 0.999, 6)
  })

  it("moves with its components (WBTC/ETH ≫ stable/stable)", () => {
    const volatile = priceOrThrow(weighted(["WBTC", 1], ["ETH", 1]))
    const stable = priceOrThrow(weighted(["USDC", 1], ["USDT", 1]))
    expect(volatile).toBeGreaterThan(stable)
    expect(volatile).toBeCloseTo(0.5 * 64000 + 0.5 * 1900, 6)
  })
})

describe("lpTokenPriceUsd — unavailable over wrong", () => {
  it("returns unavailable when any leg is unpriced (no partial number)", () => {
    const r = lpTokenPriceUsd(weighted(["ETH", 1], ["NOTATOKEN", 1]), priceOf)
    expect(r.ok).toBe(false)
    if (!r.ok) expect(r.reason).toBe("unpriced")
  })

  it("returns unavailable when a leg price is zero, NaN, or negative", () => {
    for (const bad of [0, Number.NaN, -5]) {
      const r = lpTokenPriceUsd(weighted(["ETH", 1], ["X", 1]), (s) => (s === "X" ? bad : priceOf(s)))
      expect(r.ok).toBe(false)
    }
  })

  it("rejects weights that do not sum to 1 (raw fractions)", () => {
    const r = lpTokenPriceUsd(
      [
        { symbol: "USDC", weight: 0.5 },
        { symbol: "USDT", weight: 0.4 },
      ],
      priceOf,
    )
    expect(r.ok).toBe(false)
    if (!r.ok) expect(r.reason).toBe("weights")
  })

  it("rejects a negative weight", () => {
    const r = lpTokenPriceUsd(
      [
        { symbol: "USDC", weight: 1.2 },
        { symbol: "USDT", weight: -0.2 },
      ],
      priceOf,
    )
    expect(r.ok).toBe(false)
    if (!r.ok) expect(r.reason).toBe("weights")
  })

  it("rejects an empty pool", () => {
    const r = lpTokenPriceUsd([], priceOf)
    expect(r.ok).toBe(false)
    if (!r.ok) expect(r.reason).toBe("empty")
  })
})

describe("suppliedUsd", () => {
  it("zero LP amount = $0", () => {
    expect(suppliedUsd(0, 0.9995)).toBe(0)
  })
  it("throws on a negative LP amount", () => {
    expect(() => suppliedUsd(-1, 1)).toThrow()
  })
})

describe("normalizeWeights", () => {
  it("50/25/25 from [2,1,1]", () => {
    const w = normalizeWeights([{ weight: 2 }, { weight: 1 }, { weight: 1 }]).map((i) => i.weight)
    expect(w).toEqual([0.5, 0.25, 0.25])
  })
  it("80/20 from [4,1]", () => {
    const w = normalizeWeights([{ weight: 4 }, { weight: 1 }]).map((i) => i.weight)
    expect(w).toEqual([0.8, 0.2])
  })
  it("throws when all weights are zero", () => {
    expect(() => normalizeWeights([{ weight: 0 }, { weight: 0 }])).toThrow()
  })
})
