export const USD_DECIMALS = 6
export const TOKEN_DECIMALS = 18
export const WAD_DECIMALS = 18
export const RAY_DECIMALS = 27
export const SECONDS_PER_YEAR = 365n * 24n * 60n * 60n

export const USD_SCALE = 10n ** BigInt(USD_DECIMALS)
export const TOKEN_SCALE = 10n ** BigInt(TOKEN_DECIMALS)
export const WAD = 10n ** BigInt(WAD_DECIMALS)
export const RAY = 10n ** BigInt(RAY_DECIMALS)

function abs(value: bigint) {
  return value < 0n ? -value : value
}

function pow10(decimals: number) {
  return 10n ** BigInt(decimals)
}

export function parseFixed(input: string, decimals: number) {
  const normalized = input.trim()
  if (!normalized) throw new Error("Cannot parse empty fixed-point value")

  const negative = normalized.startsWith("-")
  const unsigned = negative ? normalized.slice(1) : normalized
  const [wholePartRaw = "0", fractionPartRaw = ""] = unsigned.split(".")

  if (!/^\d+$/.test(wholePartRaw || "0") || (fractionPartRaw && !/^\d+$/.test(fractionPartRaw))) {
    throw new Error(`Invalid fixed-point value: ${input}`)
  }

  const wholePart = wholePartRaw === "" ? "0" : wholePartRaw
  const paddedFraction = `${fractionPartRaw}${"0".repeat(decimals)}`.slice(0, decimals)
  const scale = pow10(decimals)
  const wholeValue = BigInt(wholePart) * scale
  const fractionValue = paddedFraction ? BigInt(paddedFraction) : 0n
  const parsed = wholeValue + fractionValue

  return negative ? -parsed : parsed
}

export function formatFixed(value: bigint, decimals: number) {
  const negative = value < 0n
  const unsigned = abs(value)
  const scale = pow10(decimals)
  const whole = unsigned / scale
  const fraction = unsigned % scale
  const fractionText = decimals > 0 ? fraction.toString().padStart(decimals, "0").replace(/0+$/, "") : ""
  const formatted = fractionText ? `${whole.toString()}.${fractionText}` : whole.toString()
  return negative ? `-${formatted}` : formatted
}

/** A 6-decimal USD engine amount as a plain JS number, for display only. */
export function usd6ToNumber(value6: bigint): number {
  return Number.parseFloat(formatFixed(value6, USD_DECIMALS))
}

/** A WAD risk parameter as a percentage rounded to one decimal — 0.825e18 → 82.5. */
export function wadToPercent(valueWad: bigint): number {
  return Math.round(Number.parseFloat(formatFixed(valueWad, WAD_DECIMALS)) * 1000) / 10
}

export function mulDiv(a: bigint, b: bigint, denominator: bigint) {
  if (denominator === 0n) throw new Error("mulDiv denominator cannot be zero")
  return (a * b) / denominator
}

function rayMul(a: bigint, b: bigint) {
  return mulDiv(a, b, RAY)
}

function rayDiv(a: bigint, b: bigint) {
  return mulDiv(a, RAY, b)
}

function wadToRay(value: bigint) {
  return value * (RAY / WAD)
}

export function assetsToShares(assets: bigint, indexRay: bigint) {
  return rayDiv(assets, indexRay)
}

export function sharesToAssets(shares: bigint, indexRay: bigint) {
  return rayMul(shares, indexRay)
}

export function accrueLinearIndex(indexRay: bigint, aprWad: bigint, elapsedSeconds: bigint) {
  if (elapsedSeconds <= 0n || aprWad <= 0n) return indexRay
  const growthRay = mulDiv(wadToRay(aprWad), elapsedSeconds, SECONDS_PER_YEAR)
  return rayMul(indexRay, RAY + growthRay)
}

export function clampMin(value: bigint, min: bigint) {
  return value < min ? min : value
}

export function clampMax(value: bigint, max: bigint) {
  return value > max ? max : value
}
