/**
 * Calls `tick` every `ms` while the page is visible, and once more as soon as it becomes visible again; a hidden tab
 * makes no request. Returns the function that stops it. Without a document (server render) it only runs the timer.
 */
export function everyWhileVisible(tick: () => void, ms: number): () => void {
  const visible = () => typeof document === "undefined" || document.visibilityState === "visible"
  const timer = setInterval(() => {
    if (visible()) tick()
  }, ms)
  const onVisibility = () => {
    if (visible()) tick()
  }
  if (typeof document !== "undefined") document.addEventListener("visibilitychange", onVisibility)
  return () => {
    clearInterval(timer)
    if (typeof document !== "undefined") document.removeEventListener("visibilitychange", onVisibility)
  }
}
