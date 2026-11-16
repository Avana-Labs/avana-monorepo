"use client"

import { useSyncExternalStore } from "react"
import { CHAIN_KEYS, defaultChainKey, type ChainKey } from "@/app/lib/chains"

/**
 * The chain picked in the Network preference (header Preferences, mobile menu): the chain actions run on and the
 * wallet is asked to switch to. Ethereum by default; remembered per browser.
 */

const STORAGE_KEY = "avana.network"
const listeners = new Set<() => void>()
let current: ChainKey | null = null

function stored(): ChainKey | null {
  try {
    const value = window.localStorage.getItem(STORAGE_KEY)
    return CHAIN_KEYS.find((key) => key === value) ?? null
  } catch {
    return null
  }
}

export function activeChainKey(): ChainKey {
  if (current) return current
  current = (typeof window !== "undefined" ? stored() : null) ?? defaultChainKey()
  return current
}

export function setActiveChainKey(key: ChainKey) {
  current = key
  try {
    window.localStorage.setItem(STORAGE_KEY, key)
  } catch {
    // Not remembered in this browser; the choice still holds for this visit.
  }
  for (const listener of listeners) listener()
}

function subscribe(listener: () => void) {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

export function useActiveChainKey(): ChainKey {
  return useSyncExternalStore(subscribe, activeChainKey, defaultChainKey)
}
