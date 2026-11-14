import { describe, expect, it } from "vitest"
import {
  RAY,
  TOKEN_DECIMALS,
  USD_DECIMALS,
  WAD,
  WAD_DECIMALS,
  accrueLinearIndex,
  assetsToShares,
  formatFixed,
  parseFixed,
  sharesToAssets,
} from "@/app/lib/credit-engine"

describe("credit-engine units", () => {
  it("round-trips fixed-point parsing and formatting", () => {
    expect(formatFixed(parseFixed("123.456789", USD_DECIMALS), USD_DECIMALS)).toBe("123.456789")
    expect(formatFixed(parseFixed("1.25", TOKEN_DECIMALS), TOKEN_DECIMALS)).toBe("1.25")
    expect(formatFixed(parseFixed("0.075", WAD_DECIMALS), WAD_DECIMALS)).toBe("0.075")
  })

  it("converts assets to shares and back with at most one unit of loss", () => {
    const assets = parseFixed("1825.42", TOKEN_DECIMALS)
    const indexRay = RAY + parseFixed("0.0425", WAD_DECIMALS) * (RAY / WAD)
    const shares = assetsToShares(assets, indexRay)
    const roundTrip = sharesToAssets(shares, indexRay)

    expect(assets - roundTrip >= 0n ? assets - roundTrip : roundTrip - assets).toBeLessThanOrEqual(1n)
  })

  it("keeps interest indexes monotonic", () => {
    const start = RAY
    const apr = parseFixed("0.12", WAD_DECIMALS)
    const afterHour = accrueLinearIndex(start, apr, 60n * 60n)
    const afterDay = accrueLinearIndex(afterHour, apr, 24n * 60n * 60n)

    expect(afterHour).toBeGreaterThan(start)
    expect(afterDay).toBeGreaterThan(afterHour)
  })
})
