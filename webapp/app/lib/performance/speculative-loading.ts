"use client"

import { useSyncExternalStore } from "react"

type NetworkConnection = EventTarget & {
  saveData?: boolean
  effectiveType?: string
  downlink?: number
}

function connection() {
  return (navigator as Navigator & { connection?: NetworkConnection }).connection
}

/** Optional downloads must not compete with the current page on constrained links. */
export function canLoadSpeculatively() {
  if (typeof navigator === "undefined" || typeof document === "undefined") return false
  if (!navigator.onLine || document.readyState !== "complete") return false
  const network = connection()
  return !(
    network?.saveData ||
    ["slow-2g", "2g", "3g"].includes(network?.effectiveType ?? "") ||
    (typeof network?.downlink === "number" && network.downlink < 1.5)
  )
}

function subscribe(onChange: () => void) {
  const network = connection()
  window.addEventListener("load", onChange)
  window.addEventListener("online", onChange)
  window.addEventListener("offline", onChange)
  network?.addEventListener("change", onChange)
  return () => {
    window.removeEventListener("load", onChange)
    window.removeEventListener("online", onChange)
    window.removeEventListener("offline", onChange)
    network?.removeEventListener("change", onChange)
  }
}

const serverSnapshot = () => false

export function useSpeculativeLoading() {
  return useSyncExternalStore(subscribe, canLoadSpeculatively, serverSnapshot)
}
