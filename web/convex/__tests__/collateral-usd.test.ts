import { describe, expect, it } from "vitest"
import { tokenNotionalToUsd } from "../sandbox/collateralUsd"

const wad = (tokens: number) => BigInt(Math.round(tokens * 1e6)) * 10n ** 12n // exact for 6-dp inputs

describe("tokenNotionalToUsd — decimal-safe 18-dec valuation (C18)", () => {
  it("values 2.5 LP tokens at $800 = $2,000", () => {
    expect(tokenNotionalToUsd(wad(2.5), 800)).toBeCloseTo(2000, 6)
  })

  it("stays precise for large notionals where Number(raw)/1e18 would lose bits", () => {
    // 1,000,000 tokens at $65,000 = $65,000,000,000. raw = 1e24 ≫ 2^53.
    const raw = 1_000_000n * 10n ** 18n
    expect(tokenNotionalToUsd(raw, 65_000)).toBe(65_000_000_000)
  })

  it("matches the naive float product within rounding for small amounts", () => {
    const raw = wad(3.1234)
    const naive = (Number(raw) / 1e18) * 1934
    expect(tokenNotionalToUsd(raw, 1934)).toBeCloseTo(naive, 2)
  })

  it("returns 0 for a non-positive or non-finite price or amount", () => {
    expect(tokenNotionalToUsd(wad(1), 0)).toBe(0)
    expect(tokenNotionalToUsd(wad(1), -5)).toBe(0)
    expect(tokenNotionalToUsd(wad(1), Number.NaN)).toBe(0)
    expect(tokenNotionalToUsd(0n, 1934)).toBe(0)
  })
})
