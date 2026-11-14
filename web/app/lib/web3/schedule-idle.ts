/**
 * Run a callback during browser idle time, falling back to the same deadline on
 * engines without `requestIdleCallback` (Safari). Returns a cancel function.
 *
 * Used to defer the ~1MB wallet SDK mount for returning signed-in users off the
 * hydration / first-interaction critical path (see wallet-gate), so it never competes
 * with first paint or the first INP.
 */
export function scheduleIdle(callback: () => void, timeoutMs = 2000): () => void {
  if (typeof window === "undefined") return () => {}

  const requestIdle = window.requestIdleCallback
  if (typeof requestIdle === "function") {
    const id = requestIdle(() => callback(), { timeout: timeoutMs })
    return () => window.cancelIdleCallback?.(id)
  }

  // Safari has no requestIdleCallback. Preserve the caller's deferral contract;
  // a next-tick fallback puts large SDKs straight back on the critical path.
  const id = window.setTimeout(callback, timeoutMs)
  return () => window.clearTimeout(id)
}
