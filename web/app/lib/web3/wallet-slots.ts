"use client"

import { useCallback, useId, useSyncExternalStore } from "react"

/**
 * The wallet SDK must be mounted as a SIBLING of the app tree, never an ancestor: an ancestor
 * that flips on when the SDK loads remounts the whole app seconds after first paint. Components
 * needing wagmi context render an empty slot here and the SDK host portals into it, so nothing
 * in the app tree ever changes parent.
 */
type WalletSlotKind = "wallet-control-desktop" | "wallet-control-mobile" | "wrong-network-banner"

type WalletSlot = { id: string; kind: WalletSlotKind; element: HTMLElement }

let slots: WalletSlot[] = []
const listeners = new Set<() => void>()

function emit() {
  for (const listener of listeners) listener()
}

function subscribe(listener: () => void) {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

const getSnapshot = () => slots
const EMPTY: WalletSlot[] = []
const getServerSnapshot = () => EMPTY

function register(slot: WalletSlot) {
  slots = [...slots.filter((s) => s.id !== slot.id), slot]
  emit()
}

function unregister(id: string) {
  if (!slots.some((s) => s.id === id)) return
  slots = slots.filter((s) => s.id !== id)
  emit()
}

/** Ref callback for a slot element; registers on mount, unregisters on unmount. */
export function useWalletSlotRef(kind: WalletSlotKind) {
  const id = useId()
  return useCallback(
    (element: HTMLElement | null) => {
      if (element) register({ id, kind, element })
      else unregister(id)
    },
    [id, kind],
  )
}

/** Live list of registered slots (read by the SDK host to render portals). */
export function useWalletSlots(): WalletSlot[] {
  return useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot)
}
