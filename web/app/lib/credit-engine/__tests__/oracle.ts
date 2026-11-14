import Decimal from "decimal.js"
import { RAY_DECIMALS, TOKEN_DECIMALS, WAD_DECIMALS, formatFixed } from "@/app/lib/credit-engine"

Decimal.set({
  precision: 80,
  rounding: Decimal.ROUND_DOWN,
  toExpNeg: -100,
  toExpPos: 100,
})

function scaleFactor(decimals: number) {
  return new Decimal(10).pow(decimals)
}

function bigintToDecimal(value: bigint, decimals: number) {
  return new Decimal(formatFixed(value, decimals))
}

function decimalToBigint(value: Decimal.Value, decimals: number) {
  return BigInt(new Decimal(value).mul(scaleFactor(decimals)).floor().toFixed(0))
}

export function oracleAssetsToShares(assets: bigint, indexRay: bigint) {
  return decimalToBigint(
    bigintToDecimal(assets, TOKEN_DECIMALS).div(bigintToDecimal(indexRay, RAY_DECIMALS)),
    TOKEN_DECIMALS,
  )
}

export function oracleSharesToAssets(shares: bigint, indexRay: bigint) {
  return decimalToBigint(
    bigintToDecimal(shares, TOKEN_DECIMALS).mul(bigintToDecimal(indexRay, RAY_DECIMALS)),
    TOKEN_DECIMALS,
  )
}

export function oracleAccrueLinearIndex(indexRay: bigint, aprWad: bigint, elapsedSeconds: bigint) {
  const growth = bigintToDecimal(aprWad, WAD_DECIMALS)
    .mul(new Decimal(elapsedSeconds.toString()))
    .div(new Decimal(365 * 24 * 60 * 60))

  return decimalToBigint(bigintToDecimal(indexRay, RAY_DECIMALS).mul(new Decimal(1).plus(growth)), RAY_DECIMALS)
}
