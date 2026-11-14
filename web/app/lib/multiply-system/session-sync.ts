export const MULTIPLY_SESSION_SYNC_EVENT = "avana:multiply-session-sync"

export function notifyMultiplySessionChanged(walletId: string) {
  if (typeof window === "undefined") return
  window.dispatchEvent(new CustomEvent(MULTIPLY_SESSION_SYNC_EVENT, { detail: { walletId } }))
}
