"use client"

import { Component, type ErrorInfo, type ReactNode } from "react"
import { useConvexAuth } from "convex/react"
import { ConvexAvanaSessionsProvider } from "./convex-avana-sessions-provider"
import { PendingConvexSessionProvider } from "./pending-convex-session-provider"

class ConvexSessionErrorBoundary extends Component<{ walletId: string; children: ReactNode }, { hasError: boolean }> {
  state = { hasError: false }

  static getDerivedStateFromError() {
    return { hasError: true }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    if (process.env.NODE_ENV !== "production") {
      console.error("Convex session failed; falling back to local Avana session.", error, info.componentStack)
    }
  }

  render() {
    if (this.state.hasError) {
      return (
        <PendingConvexSessionProvider walletId={this.props.walletId}>
          {this.props.children}
        </PendingConvexSessionProvider>
      )
    }
    return this.props.children
  }
}

export function ConvexSessionProvider({ walletId, children }: { walletId: string; children: ReactNode }) {
  const { isAuthenticated } = useConvexAuth()

  // Instant Paint: keep product chrome mounted on the local session while Convex
  // auth settles. Returning null blanked the whole tree (open-gate / SIWE restore).
  if (!isAuthenticated) {
    return (
      <div aria-label="Authenticating wallet session">
        <PendingConvexSessionProvider walletId={walletId}>{children}</PendingConvexSessionProvider>
      </div>
    )
  }

  return (
    <ConvexSessionErrorBoundary walletId={walletId}>
      <ConvexAvanaSessionsProvider walletId={walletId}>{children}</ConvexAvanaSessionsProvider>
    </ConvexSessionErrorBoundary>
  )
}
