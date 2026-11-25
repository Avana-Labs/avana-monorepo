const DECIMAL_INPUT_PATTERN = /^(?:\d+(?:\.\d*)?|\.\d+)$/

// Cap the accepted magnitude far below 1e21, the point where Number.toFixed
// switches to exponential notation ("1e+30") that downstream fixed-point
// parsing rejects and throws on. Any amount past this is treated as invalid
// rather than crashing the preview.
const MAX_ACTION_AMOUNT = 1e15

/**
 * Validate a decimal amount as the user types, without silently rewriting it. A comma is accepted
 * as the decimal separator (the app ships comma-decimal locales like de/fr/es), so "1,5" normalizes
 * to "1.5" rather than "15". Only the first separator is kept; a stray second separator or any other
 * invalid character stops parsing rather than concatenating the digits around it ("1.2.3"→"1.2",
 * "1e9"→"1", "-5"→""). A trailing "." is preserved so incremental typing stays fluid.
 */
export function sanitizeDecimalInput(value: string): string {
  let result = ""
  let hasSeparator = false
  for (const char of value.trim()) {
    if (char >= "0" && char <= "9") {
      result += char
    } else if (char === "." || char === ",") {
      if (hasSeparator) break
      result += "."
      hasSeparator = true
    } else {
      break
    }
  }
  return result
}

export function parsePositiveActionAmount(value: string): number | null {
  const trimmed = value.trim()
  if (!DECIMAL_INPUT_PATTERN.test(trimmed)) return null

  const parsed = Number(trimmed)
  if (!Number.isFinite(parsed) || parsed <= 0 || parsed > MAX_ACTION_AMOUNT) return null

  return parsed
}

export function parseActionPercentBps(value: string): number | null {
  const parsed = parsePositiveActionAmount(value)
  if (parsed == null || parsed > 100) return null

  return Math.round(parsed * 100)
}
