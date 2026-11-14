export const PAGE_LOADING_EVENT = "avana:page-loading-start"

export function triggerPageLoading() {
  if (typeof window === "undefined") return
  window.dispatchEvent(new Event(PAGE_LOADING_EVENT))
}
