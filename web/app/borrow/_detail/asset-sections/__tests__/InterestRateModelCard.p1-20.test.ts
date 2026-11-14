import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { buildAssetDetail, resolveAsset } from "@/app/lib/borrow-detail/asset.mock"
import {
  buildInterestRateModelParams,
  resolveInterestRateModelParams,
} from "@/app/lib/borrow-detail/protocol-parameters"

describe("InterestRateModelCard market params", () => {
  it("p1-20: asset detail ships non-constant optimal utilization params", () => {
    const usdc = buildAssetDetail(resolveAsset("uni-v3-stable:usdc")!)
    const dai = buildAssetDetail(resolveAsset("uni-v2:dai")!)

    const usdcOptimal = resolveInterestRateModelParams(usdc.protocolParameters).optimalUtilizationPct
    const daiOptimal = resolveInterestRateModelParams(dai.protocolParameters).optimalUtilizationPct

    expect(usdcOptimal).not.toBe(92)
    expect(daiOptimal).not.toBe(92)
    expect(usdcOptimal).not.toBe(daiOptimal)
  })

  it("p1-20: InterestRateModelCard reads optimal util and slopes from detail params", () => {
    const source = readFileSync(resolve(__dirname, "../InterestRateModelCard.tsx"), "utf8")

    expect(source).not.toMatch(/const optimalUtilization = 92/)
    expect(source).toMatch(/resolveInterestRateModelParams/)
    expect(source).toMatch(/slopeBelowOptimalPct/)
    expect(source).toMatch(/slopeAboveOptimalPct/)
    expect(source).toMatch(/buildBorrowInterestRateCurve/)
    expect(source).toMatch(/probeInterestRateModel/)
    expect(source).toMatch(/InterestRateModelChart/)
  })

  it("InterestRateModelChart exposes pointer probe and synced current label", () => {
    const source = readFileSync(resolve(__dirname, "../InterestRateModelChart.tsx"), "utf8")
    expect(source).toMatch(/onPointerMove/)
    expect(source).toMatch(/interest-rate-model-tooltip/)
    expect(source).toMatch(/formatPercent\(currentUtilization, \{ dp: 2 \}\)/)
    expect(source).toMatch(/Borrow APY/)
  })

  it("p1-20: seeded market params vary by asset id", () => {
    const first = buildInterestRateModelParams("uni-v3-stable:usdc", 4.2)
    const second = buildInterestRateModelParams("curve-stable:usdc", 4.2)

    expect(first.optimalUtilizationPct).not.toBe(second.optimalUtilizationPct)
  })
})
