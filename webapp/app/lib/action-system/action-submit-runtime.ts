type ActionSubmitResult = {
  receipt: {
    status: string
    error?: string | null
    hash?: string | null
  }
}

const ALLOWANCE_SIMULATED_MS = 900
const WALLET_SIGN_SIMULATED_MS = 1200
/** Long enough for the ProcessingNarration lines to play before the receipt appears. Synthetic-only. */
export const PROCESSING_SIMULATED_MS = 4200
const RECONCILIATION_STAGE_SIMULATED_MS = 300

// Vitest drives this flow with real timers, so skip the UX pacing there; the real app and
// Playwright E2E keep the readable delays.
const SKIP_SIMULATED_DELAYS = typeof process !== "undefined" && process.env?.VITEST === "true"

/**
 * Ceiling on the "processing" wait for execute(); without it a stalled Convex socket leaves the
 * CTA disabled forever. On timeout we reject so the caller reaches the error stage.
 */
const EXECUTE_TIMEOUT_MS = 30_000
const EXECUTE_TIMEOUT_MESSAGE = "The transaction timed out. Check your connection and try again."

function delay(ms: number) {
  if (SKIP_SIMULATED_DELAYS) return Promise.resolve()
  return new Promise<void>((resolve) => {
    window.setTimeout(resolve, ms)
  })
}

/**
 * Reject after `ms` if `promise` hasn't settled. A timeout does NOT cancel the underlying write —
 * the intentId idempotency key collapses a late commit or a retry onto one row.
 */
function raceWithTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  if (!ms || ms <= 0) return promise
  let timer: ReturnType<typeof setTimeout> | undefined
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(EXECUTE_TIMEOUT_MESSAGE)), ms)
  })
  return Promise.race([promise, timeout]).finally(() => {
    if (timer) clearTimeout(timer)
  })
}

export async function runActionSubmitFlow<T extends ActionSubmitResult>(options: {
  simulated: boolean
  needsAllowance?: boolean
  /** Override the execute() timeout (ms). 0/undefined uses EXECUTE_TIMEOUT_MS. */
  timeoutMs?: number
  onStage: (stage: import("./contracts").ActionStage) => void
  execute: () => Promise<T>
}): Promise<T> {
  if (options.needsAllowance) {
    options.onStage("approve_allowance")
    if (options.simulated) await delay(ALLOWANCE_SIMULATED_MS)
  }

  options.onStage("wallet_sign")
  if (options.simulated) await delay(WALLET_SIGN_SIMULATED_MS)

  options.onStage("processing")
  if (options.simulated) await delay(PROCESSING_SIMULATED_MS)

  options.onStage("submitted")
  const result = await raceWithTimeout(options.execute(), options.timeoutMs ?? EXECUTE_TIMEOUT_MS)
  options.onStage("confirmed")
  if (options.simulated) await delay(RECONCILIATION_STAGE_SIMULATED_MS)
  options.onStage("refreshing_position")
  if (options.simulated) await delay(RECONCILIATION_STAGE_SIMULATED_MS)
  options.onStage("reconciled")
  if (options.simulated) await delay(RECONCILIATION_STAGE_SIMULATED_MS)
  return result
}
