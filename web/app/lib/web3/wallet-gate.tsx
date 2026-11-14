"use client"

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react"
import { getSiweSession, subscribeSiwe } from "@/app/lib/siwe/auth-store"
import { IS_DEV_SHORTCUT_MODE } from "@/app/lib/test-mode"
import { scheduleIdle } from "./schedule-idle"

/**
 * Keeps the ~1MB wallet SDK off the critical path: a tiny wagmi-free context that is always
 * mounted, while the SDK loads only once this gate goes `active` (explicit "Connect" click, or
 * a persisted SIWE token detected just after first paint). Guests who never connect never
 * download it. See `web3-provider-boundary.tsx`.
 */
type WalletGate = {
  /** Whether the wallet SDK is (being) mounted. When false, no wagmi context exists. */
  active: boolean
  /**
   * Mount the SDK and auto-open the connect modal once it is ready (used by "Get Started"). When
   * the SDK is already mounted, bumps `openRequest` so the mounted control opens the modal.
   */
  connect: () => void
  /** Increments on each `connect()` after the SDK mounted; the wallet control opens the modal. */
  openRequest: number
  /** Mount the SDK without opening a modal (used to restore a persisted session). */
  activate: () => void
  /** One-shot read: did the last activation ask the modal to auto-open? Consumed once mounted. */
  consumeAutoOpen: () => boolean
  /** ConnectKit modal open state, mirrored out of the (lazy) provider so the header can read it. */
  modalOpen: boolean
  setModalOpen: (open: boolean) => void
}

const WalletGateContext = createContext<WalletGate | null>(null)

// Module-scoped so repeated activations share ONE import (and the boundary's dynamic()
// import dedupes against it). We flip `active` only AFTER the module resolves, so the app
// stays painted while the chunk downloads instead of flashing a blank.
let web3ModulePromise: Promise<typeof import("@/app/lib/web3/web3-provider")> | null = null
export function loadWeb3Module() {
  if (!web3ModulePromise) {
    web3ModulePromise = import("@/app/lib/web3/web3-provider")
  }
  return web3ModulePromise
}
const preloadWeb3 = loadWeb3Module

export function WalletGateProvider({ children }: { children: ReactNode }) {
  const [active, setActive] = useState(false)
  const [modalOpen, setModalOpen] = useState(false)
  const [openRequest, setOpenRequest] = useState(0)
  const autoOpenRef = useRef(false)
  const activatedRef = useRef(false)

  const goActive = useCallback((autoOpen: boolean) => {
    if (autoOpen) autoOpenRef.current = true
    if (activatedRef.current) return
    activatedRef.current = true
    void preloadWeb3().then(() => setActive(true))
  }, [])

  const activate = useCallback(() => goActive(false), [goActive])
  const connect = useCallback(() => {
    if (activatedRef.current) setOpenRequest((count) => count + 1)
    else goActive(true)
  }, [goActive])

  const consumeAutoOpen = useCallback(() => {
    const value = autoOpenRef.current
    autoOpenRef.current = false
    return value
  }, [])

  // Returning signed-in users: a persisted SIWE token means the wallet stack is worth
  // mounting (account pill, wrong-network detection, disconnect). Do it AFTER first paint so
  // hydration matches the server (which renders no wallet SDK) and the heavy JS is off the
  // critical path — and defer the initial mount to browser idle (scheduleIdle) so downloading
  // and initializing ~1MB of wallet SDK never competes with hydration or the first INP. Guests
  // (no token) never trip this. Dev open-gate/test mode has no real wallet, so it never mounts.
  useEffect(() => {
    if (IS_DEV_SHORTCUT_MODE) return
    // Wait for `load` first: the ~500KB (gzipped) SDK otherwise starts downloading during
    // hydration and starves the session/Convex chunks and the Convex WebSocket handshake on
    // slow links (measured: +3s to first content for returning users on a throttled mobile).
    let cancelIdle = () => {}
    const startWhenSettled = () => {
      cancelIdle = scheduleIdle(activate, 8000)
    }
    const hasToken = getSiweSession() != null
    if (hasToken && document.readyState === "complete") startWhenSettled()
    else if (hasToken) window.addEventListener("load", startWhenSettled, { once: true })
    // A token can also appear later — e.g. sign-in completing in another tab. That is a direct
    // response to user intent, so mount immediately rather than waiting for idle.
    const unsubscribe = subscribeSiwe(() => {
      if (getSiweSession() != null) activate()
    })
    return () => {
      window.removeEventListener("load", startWhenSettled)
      cancelIdle()
      unsubscribe()
    }
  }, [activate])

  const value = useMemo<WalletGate>(
    () => ({ active, connect, openRequest, activate, consumeAutoOpen, modalOpen, setModalOpen }),
    [active, connect, openRequest, activate, consumeAutoOpen, modalOpen],
  )

  return <WalletGateContext.Provider value={value}>{children}</WalletGateContext.Provider>
}

/** The gate, or null outside a provider (isolated component tests). */
export function useOptionalWalletGate(): WalletGate | null {
  return useContext(WalletGateContext)
}

export function useWalletGate(): WalletGate {
  const ctx = useContext(WalletGateContext)
  if (!ctx) {
    throw new Error("useWalletGate must be used within a WalletGateProvider")
  }
  return ctx
}
