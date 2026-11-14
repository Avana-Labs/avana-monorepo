import { describe, expect, it } from "vitest"
import {
  RAY,
  TOKEN_DECIMALS,
  WAD,
  WAD_DECIMALS,
  accrueLinearIndex,
  assetsToShares,
  parseFixed,
  sharesToAssets,
} from "@/app/lib/credit-engine"
import { oracleAccrueLinearIndex, oracleAssetsToShares, oracleSharesToAssets } from "./oracle"

describe("credit-engine oracle parity", () => {
  it("matches the decimal oracle for share conversions", () => {
    const assets = parseFixed("2048.125", TOKEN_DECIMALS)
    const indexRay = RAY + parseFixed("0.0635", WAD_DECIMALS) * (RAY / WAD)

    expect(assetsToShares(assets, indexRay)).toBe(oracleAssetsToShares(assets, indexRay))
    expect(sharesToAssets(assetsToShares(assets, indexRay), indexRay)).toBe(
      oracleSharesToAssets(oracleAssetsToShares(assets, indexRay), indexRay),
    )
  })

  it("matches the decimal oracle for linear interest accrual", () => {
    const index = RAY
    const apr = parseFixed("0.185", WAD_DECIMALS)
    const elapsed = 7n * 24n * 60n * 60n

    expect(accrueLinearIndex(index, apr, elapsed)).toBe(oracleAccrueLinearIndex(index, apr, elapsed))
  })
})
