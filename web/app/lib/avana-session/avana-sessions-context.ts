"use client"

import { createContext, useContext } from "react"
import type { AvanaIdentity, AvanaSessions, BorrowSession, LendSession, SwapSession } from "./avana-sessions-provider"

// These context objects + read hooks live in their own lightweight module (react + type-only
// imports, which SWC erases) so a component can read a session slice WITHOUT statically pulling in
// AvanaSessionsProvider and its heavy dependency graph — every
// borrow/lend/swap session. The global search command's
// useBorrowSessionContextOptional was dragging all of that (~413KB of Convex JS) onto every page
// with the header, including the guest landing. AvanaSessionsProvider imports these same context
// objects to provide them, and re-exports the read hooks below for backward compatibility.

export const AvanaSessionsContext = createContext<AvanaSessions | null>(null)
export const AvanaIdentityContext = createContext<AvanaIdentity | null>(null)
export const BorrowSessionContext = createContext<BorrowSession | null>(null)
export const LendSessionContext = createContext<LendSession | null>(null)
export const SwapSessionContext = createContext<SwapSession | null>(null)

export function useAvanaSessions() {
  const context = useContext(AvanaSessionsContext)
  if (!context) {
    throw new Error("useAvanaSessions must be used within AvanaSessionsProvider")
  }
  return context
}

export function useOptionalAvanaSessions() {
  return useContext(AvanaSessionsContext)
}

export function useAvanaIdentity() {
  const context = useContext(AvanaIdentityContext)
  if (!context) {
    throw new Error("useAvanaIdentity must be used within AvanaSessionsProvider")
  }
  return context
}

export function useBorrowSessionContext() {
  const context = useContext(BorrowSessionContext)
  if (!context) {
    throw new Error("useBorrowSessionContext must be used within AvanaSessionsProvider")
  }
  return context
}

/**
 * Returns the borrow session when mounted inside AvanaSessionsProvider, null otherwise.
 * Use in components that appear in BOTH session-scoped surfaces (dashboard, borrow) AND
 * chromed shells that may render without a session (e.g. the global search command
 * inside a test-only wrapper). Session-scoped consumers should keep useBorrowSessionContext.
 */
export function useBorrowSessionContextOptional() {
  return useContext(BorrowSessionContext)
}

export function useLendSessionContext() {
  const context = useContext(LendSessionContext)
  if (!context) {
    throw new Error("useLendSessionContext must be used within AvanaSessionsProvider")
  }
  return context
}

/** The Lend session when mounted inside AvanaSessionsProvider, null otherwise. */
export function useLendSessionContextOptional() {
  return useContext(LendSessionContext)
}

export function useSwapSessionContext() {
  const context = useContext(SwapSessionContext)
  if (!context) {
    throw new Error("useSwapSessionContext must be used within AvanaSessionsProvider")
  }
  return context
}
