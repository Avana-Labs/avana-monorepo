import { codedError } from "../codedError"
/** Pure input and fixed-point invariants shared by sandbox transaction handlers. */

export const MAX_FIXED_POINT_DIGITS = 80
export const MAX_POSITION_LEGS = 32
export const MAX_IDENTIFIER_LENGTH = 200
export const MAX_MULTIPLIER = 10
export const BORROW_FALLBACK_LIQUIDATION_PCT = 85

export function requireBoundedIdentifier(value: string, field: string) {
  if (value.length === 0 || value.length > MAX_IDENTIFIER_LENGTH) {
    throw codedError(`INVALID_INPUT: ${field} must contain 1 to ${MAX_IDENTIFIER_LENGTH} characters.`)
  }
}

export function requireUnsignedInteger(value: string, field: string) {
  if (value.length === 0 || value.length > MAX_FIXED_POINT_DIGITS || !/^\d+$/.test(value)) {
    throw codedError(`INVALID_POSITION: ${field} must be an unsigned integer string.`)
  }
}

export function usd6Number(value?: string) {
  return Number(BigInt(value ?? "0")) / 1_000_000
}

export function assertClose(actual: number, expected: number, field: string, tolerance = 0.02) {
  if (!Number.isFinite(actual) || Math.abs(actual - expected) > tolerance) {
    throw codedError(`INVALID_TRANSITION: ${field} does not match the server recomputation.`)
  }
}

export function liquidationThresholdFromMaxLtv(maxLtvPct: number) {
  return Math.min(maxLtvPct + 10, 95)
}

export function numberToUsd6(value: number) {
  return Math.max(0, Math.round(value * 1_000_000)).toString()
}

export function ratioToWad(value: number | null) {
  if (value === null || !Number.isFinite(value)) return null
  return Math.max(0, Math.round(value * 1_000_000_000) * 1_000_000_000).toString()
}
