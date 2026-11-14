import { describe, expect, it } from "vitest"
import fc from "fast-check"
import type { BorrowSystemState } from "@/app/lib/credit-engine"
import {
  RAY,
  USD_SCALE,
  WAD,
  assetsToShares,
  calculateCreditMetrics,
  currentDebtValueUsd6,
  sharesToAssets,
} from "@/app/lib/credit-engine"
import { EXAMPLE_UNI_USDC_ASSET_ID, makeExampleBorrowSystemState } from "./fixtures"

const BPS_TO_WAD = 100_000_000_000_000n

function wadFromBps(bps: number) {
  return BigInt(bps) * BPS_TO_WAD
}

function usdFromInt(value: number) {
  return BigInt(value) * USD_SCALE
}

function makeRandomState(params: {
  collateralFactorBps: number
  liquidationThresholdBps: number
  riskScoreBps: number
  feeApyBps: number
  lpPriceUsd: number
  walletBalanceUsd: number
  collateralShares: number
  principalCollateralShares: number
  baseBorrowAprBps: number
  debtPrincipalUsd: number
  debtIndexBps: number
}): BorrowSystemState {
  const state = makeExampleBorrowSystemState()
  const market = state.markets["uni-v3-bluechip-weth-usdc"]!
  const asset = state.assets[EXAMPLE_UNI_USDC_ASSET_ID]!
  const account = state.accounts["wallet-1"]!
  const collateralPosition = account.collateralPositions[0]!
  const debtPosition = account.debtPositions[0]!

  market.riskConfig.collateralFactorWad = wadFromBps(params.collateralFactorBps)
  market.riskConfig.liquidationThresholdWad = wadFromBps(params.liquidationThresholdBps)
  market.riskConfig.riskScoreWad = wadFromBps(params.riskScoreBps)
  market.snapshot.feeApyWad = wadFromBps(params.feeApyBps)
  market.snapshot.lpTokenPriceUsd6 = usdFromInt(params.lpPriceUsd)
  collateralPosition.collateralShares = BigInt(params.collateralShares) * WAD
  collateralPosition.principalTokenAmount = BigInt(params.principalCollateralShares) * WAD
  account.walletBalanceUsd6 = usdFromInt(params.walletBalanceUsd)

  asset.borrowConfig.baseBorrowAprWad = wadFromBps(params.baseBorrowAprBps)
  debtPosition.principalBorrowedUsd6 = usdFromInt(params.debtPrincipalUsd)
  debtPosition.debtSharesUsd6 = usdFromInt(params.debtPrincipalUsd)
  debtPosition.debtIndexRay = RAY + wadFromBps(params.debtIndexBps) * (RAY / WAD)
  debtPosition.borrowRateWad = wadFromBps(params.baseBorrowAprBps)

  return state
}

describe("borrow credit property tests", () => {
  it("keeps shares -> assets -> shares round-trips within one unit", () => {
    fc.assert(
      fc.property(
        fc.bigInt({ min: 1n, max: 10_000_000_000_000_000_000_000n }),
        fc.bigInt({ min: RAY, max: RAY * 5n }),
        (assets, indexRay) => {
          const shares = assetsToShares(assets, indexRay)
          const roundTrip = assetsToShares(sharesToAssets(shares, indexRay), indexRay)
          const delta = roundTrip >= shares ? roundTrip - shares : shares - roundTrip
          expect(delta).toBeLessThanOrEqual(1n)
        },
      ),
      { numRuns: 250 },
    )
  })

  it("never decreases debt value when the debt index increases", () => {
    fc.assert(
      fc.property(
        fc.bigInt({ min: 1n, max: 50_000_000_000n }),
        fc.bigInt({ min: RAY, max: RAY * 3n }),
        fc.bigInt({ min: RAY, max: RAY * 4n }),
        (shares, indexA, indexB) => {
          fc.pre(indexB >= indexA)
          expect(
            currentDebtValueUsd6({
              id: "d",
              assetId: EXAMPLE_UNI_USDC_ASSET_ID,
              baseAssetId: "usdc",
              spokeId: "uni-v3-bluechip",
              debtSharesUsd6: shares,
              debtIndexRay: indexB,
              borrowRateWad: 0n,
              principalBorrowedUsd6: shares,
            }),
          ).toBeGreaterThanOrEqual(
            currentDebtValueUsd6({
              id: "d",
              assetId: EXAMPLE_UNI_USDC_ASSET_ID,
              baseAssetId: "usdc",
              spokeId: "uni-v3-bluechip",
              debtSharesUsd6: shares,
              debtIndexRay: indexA,
              borrowRateWad: 0n,
              principalBorrowedUsd6: shares,
            }),
          )
        },
      ),
      { numRuns: 250 },
    )
  })

  it("keeps credit metrics inside formula invariants for random valid states", () => {
    const arb = fc
      .record({
        collateralFactorBps: fc.integer({ min: 1000, max: 8500 }),
        liquidationThresholdBps: fc.integer({ min: 1500, max: 9500 }),
        riskScoreBps: fc.integer({ min: 0, max: 9000 }),
        feeApyBps: fc.integer({ min: 0, max: 3500 }),
        lpPriceUsd: fc.integer({ min: 100, max: 5000 }),
        walletBalanceUsd: fc.integer({ min: 0, max: 250000 }),
        collateralShares: fc.integer({ min: 1, max: 250 }),
        principalCollateralShares: fc.integer({ min: 1, max: 250 }),
        baseBorrowAprBps: fc.integer({ min: 100, max: 2500 }),
        debtPrincipalUsd: fc.integer({ min: 0, max: 500000 }),
        debtIndexBps: fc.integer({ min: 0, max: 2500 }),
      })
      .filter(
        (value) =>
          value.liquidationThresholdBps >= value.collateralFactorBps &&
          value.collateralShares >= value.principalCollateralShares,
      )

    fc.assert(
      fc.property(arb, (params) => {
        const state = makeRandomState(params)
        const metrics = calculateCreditMetrics(state, "wallet-1")

        expect(metrics.availableCreditUsd6).toBeGreaterThanOrEqual(0n)
        expect(metrics.riskPremiumWad).toBeGreaterThanOrEqual(0n)
        expect(metrics.borrowAprWad).toBeGreaterThanOrEqual(metrics.baseBorrowAprWad)
        expect(metrics.liquidationBufferUsd6).toBe(metrics.liquidationValueUsd6 - metrics.totalBorrowedUsd6)
        if (metrics.totalBorrowedUsd6 === 0n) {
          expect(metrics.availableCreditUsd6).toBe(metrics.creditLimitUsd6)
        }
      }),
      { numRuns: 250 },
    )
  })
})
