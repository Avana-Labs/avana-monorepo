/** Catalog leverage labels are shown as-is; named so the division below stays explicit. */
export const MULTIPLY_CATALOG_LEVERAGE_SCALE = 1

/** Multiply action modal slider range (independent of per-market public caps). */
export const MULTIPLY_ACTION_MIN_LEVERAGE = 1
/** Engine / validation hard ceiling. */
export const MULTIPLY_ACTION_MAX_LEVERAGE = 10
/** Slider right end: just under the engine ceiling so ticks land evenly at step 0.01. */
export const MULTIPLY_ACTION_SLIDER_MAX = 9.99
export const MULTIPLY_ACTION_SLIDER_STEP = 0.01
const MULTIPLY_DEFAULT_LEVERAGE = 1.1

/**
 * Per-market public cap clamped to the global action ceiling, for defaults and display. The
 * slider itself always spans the full range; publicMax is enforced as engine validation, not
 * a thumb clamp.
 */
export function resolveMultiplyMarketMaxLeverage(publicMaxMultiplier: number | undefined) {
  if (!Number.isFinite(publicMaxMultiplier) || publicMaxMultiplier == null || publicMaxMultiplier < 1) {
    return MULTIPLY_ACTION_MAX_LEVERAGE
  }

  const actionCap = publicMaxMultiplier / MULTIPLY_CATALOG_LEVERAGE_SCALE
  return Math.min(MULTIPLY_ACTION_MAX_LEVERAGE, actionCap)
}

/**
 * Single source of the per-market "max leverage" figure across the Multiply page. This is the
 * advertised public cap — NOT the recommended/safe cap and NOT the action-slider clamp.
 */
export function resolveMultiplyMarketDisplayMaxLeverage(publicMaxMultiplier: number | undefined) {
  if (!Number.isFinite(publicMaxMultiplier) || publicMaxMultiplier == null || publicMaxMultiplier < 1) {
    return 1
  }
  return publicMaxMultiplier
}

export function resolveDefaultMultiplyLeverage(
  publicMaxMultiplier: number | undefined,
  recommendedMaxMultiplier?: number,
) {
  const publicMax = resolveMultiplyMarketMaxLeverage(publicMaxMultiplier)
  const recommendedMax = Number.isFinite(recommendedMaxMultiplier)
    ? Math.max(MULTIPLY_ACTION_MIN_LEVERAGE, recommendedMaxMultiplier!)
    : publicMax
  return Math.min(publicMax, recommendedMax, MULTIPLY_DEFAULT_LEVERAGE)
}

function stepDecimals(step: number) {
  const fraction = String(step).split(".")[1]
  return fraction?.length ?? 0
}

/**
 * Snap a leverage value to the slider's step grid using the SAME rounding rule as the ruler thumb
 * (`round((v - min) / step)`), then clamp. Keeps the pill and projection summary on one value.
 */
export function snapMultiplierToStep(value: number, min: number, max: number, step = 0.01): number {
  if (!Number.isFinite(value)) return min
  const safeStep = Number.isFinite(step) && step > 0 ? step : 0.1
  const steps = Math.round((value - min) / safeStep)
  const snapped = min + steps * safeStep
  const clamped = Math.min(max, Math.max(min, snapped))
  return Number(clamped.toFixed(stepDecimals(safeStep)))
}

export function getDefaultDeleverageMultiplier(currentMultiplier: number) {
  if (!Number.isFinite(currentMultiplier)) return String(MULTIPLY_ACTION_MIN_LEVERAGE)
  const lowered = Math.max(MULTIPLY_ACTION_MIN_LEVERAGE, currentMultiplier - 0.5)
  return String(Number(lowered.toFixed(2)))
}

export function getDeleverageMultiplierMax(currentMultiplier: number, step = 0.1) {
  if (!Number.isFinite(currentMultiplier)) return MULTIPLY_ACTION_MIN_LEVERAGE
  const upperBound = Math.max(MULTIPLY_ACTION_MIN_LEVERAGE, currentMultiplier - step)
  return Number(upperBound.toFixed(2))
}

/** True when deleverage has no room below current leverage — Close is the only exit. */
export function isDeleverageCloseOnly(currentMultiplier: number, step = 0.1) {
  return getDeleverageMultiplierMax(currentMultiplier, step) <= MULTIPLY_ACTION_MIN_LEVERAGE + 1e-9
}
