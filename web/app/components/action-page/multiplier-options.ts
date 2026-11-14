const PRESET_MULTIPLIERS = [1.5, 2, 3, 5, 7, 10]

/**
 * Build the set of selectable leverage presets for a market, never exceeding
 * its public maximum. The max is floored to one decimal so the highest option
 * is always <= the real cap (rounding up would produce a blocked preview).
 */
export function buildMultiplierOptions(publicMaxMultiplier: number): number[] {
  const max = Number.isFinite(publicMaxMultiplier) && publicMaxMultiplier >= 1 ? publicMaxMultiplier : 5
  const flooredMax = Math.floor(max * 10) / 10
  const options = PRESET_MULTIPLIERS.filter((preset) => preset <= flooredMax + 1e-9)

  if (flooredMax >= 1.1 && !options.some((option) => Math.abs(option - flooredMax) < 1e-9)) {
    options.push(flooredMax)
  }

  if (options.length === 0) options.push(Math.max(1.1, flooredMax))

  return options.sort((left, right) => left - right)
}

/**
 * Snap a multiplier to a valid option for the market. If the value is already
 * a valid option it is kept; otherwise it falls to the largest option that does
 * not exceed it, or the smallest option when the value is below the range.
 */
export function clampMultiplierToOptions(value: number, options: number[]): number {
  if (options.length === 0) return value
  if (options.some((option) => Math.abs(option - value) < 1e-9)) return value

  const notExceeding = options.filter((option) => option <= value)
  if (notExceeding.length > 0) return notExceeding[notExceeding.length - 1]!
  return options[0]!
}
