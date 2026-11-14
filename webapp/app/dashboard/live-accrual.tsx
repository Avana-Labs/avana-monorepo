"use client"

import * as React from "react"

const YEAR_MS = 365 * 24 * 60 * 60 * 1000

/**
 * Live, real-time interest accrual — computed ENTIRELY on the client from stable inputs
 * (principal-derived yearly USD rate + the moment supply started) plus the wall clock, and
 * re-rendered on requestAnimationFrame so it counts up continuously. The value shows its
 * settled amount immediately (no flash to zero) and then ticks upward.
 *
 * WHY NOT read the Convex "earned" value: the ledger materialises interest lazily, so the
 * server snapshot is $0 for a freshly-supplied position — binding the display to it froze the
 * field at $0. Any interest the ledger HAS recorded is passed as `baseUsd`; the live accrual
 * adds on top, so the animation and the server number never fight (the caveat to watch for).
 * Because every input is read through a ref, a Convex re-render (fresh rate/anchor) is picked
 * up on the next frame without restarting the counter.
 */
function useAccruedUsd(anchorMs: number | null, ratePerYearUsd: number, baseUsd: number): number {
  const inputs = React.useRef({ anchorMs, ratePerYearUsd, baseUsd })
  inputs.current = { anchorMs, ratePerYearUsd, baseUsd }
  const [, tick] = React.useReducer((n: number) => n + 1, 0)

  React.useEffect(() => {
    let raf = 0
    let last = 0
    const loop = (ts: number) => {
      // ~20fps: smooth to the eye at a fraction of the cost of repainting every frame.
      if (ts - last >= 50) {
        last = ts
        tick()
      }
      raf = requestAnimationFrame(loop)
    }
    raf = requestAnimationFrame(loop)
    return () => cancelAnimationFrame(raf)
  }, [])

  const { anchorMs: anchor, ratePerYearUsd: rate, baseUsd: base } = inputs.current
  if (anchor == null) return base
  return base + Math.max(0, (Date.now() - anchor) / YEAR_MS) * rate
}

function formatLiveUsd(value: number, fractionDigits: number): string {
  return `$${value.toLocaleString(undefined, { minimumFractionDigits: fractionDigits, maximumFractionDigits: fractionDigits })}`
}

/**
 * Interest accrued in real time. `ratePerYearUsd` = principal × APY (e.g. $300k × 4.51%);
 * `anchorMs` is when the earliest position was supplied. Extra decimals are intentional — a
 * live counter that visibly ticks reads as "earning right now" rather than a static figure.
 */
export function LiveInterestEarnedUsd({
  anchorMs,
  ratePerYearUsd,
  baseUsd = 0,
  fractionDigits = 4,
}: {
  anchorMs: number | null
  ratePerYearUsd: number
  baseUsd?: number
  fractionDigits?: number
}) {
  const value = useAccruedUsd(anchorMs, ratePerYearUsd, baseUsd)
  return <span className="tabular-nums">{formatLiveUsd(value, fractionDigits)}</span>
}

/**
 * Debt interest accruing in real time — the same client-side accumulator as
 * {@link LiveInterestEarnedUsd}, for the owed (cost) side. `baseUsd` is the interest already
 * accrued to the snapshot moment, `anchorMs` is that moment, and `ratePerYearUsd` = debt × borrow
 * APY, so the figure ticks up from the current amount without double-counting. The red tone is
 * applied by the caller.
 */
export function LiveInterestOwedUsd({
  anchorMs,
  ratePerYearUsd,
  baseUsd = 0,
  fractionDigits = 4,
}: {
  anchorMs: number | null
  ratePerYearUsd: number
  baseUsd?: number
  fractionDigits?: number
}) {
  const value = useAccruedUsd(anchorMs, ratePerYearUsd, baseUsd)
  return <span className="tabular-nums">{formatLiveUsd(value, fractionDigits)}</span>
}

/**
 * Yield generated so far as a percentage of principal, ticking in real time. Small on a fresh
 * position, so precision adapts (more decimals while it is under a hundredth of a percent) — it
 * still reads as a live, non-zero number instead of a flat 0.00%.
 */
export function LiveYieldGeneratedPct({
  anchorMs,
  ratePerYearUsd,
  principalUsd,
  baseUsd = 0,
}: {
  anchorMs: number | null
  ratePerYearUsd: number
  principalUsd: number
  baseUsd?: number
}) {
  const accrued = useAccruedUsd(anchorMs, ratePerYearUsd, baseUsd)
  const pct = principalUsd > 0 ? (accrued / principalUsd) * 100 : 0
  const digits = pct > 0 && pct < 0.01 ? 6 : pct < 1 ? 4 : 2
  return (
    <span className="tabular-nums">
      {pct.toLocaleString(undefined, { minimumFractionDigits: digits, maximumFractionDigits: digits })}%
    </span>
  )
}
