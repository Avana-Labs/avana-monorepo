"use client"

import { useWrongNetworkState } from "@/app/lib/web3/wrong-network-context"

type ActionNetworkGuard = {
  /** True when a wallet is connected on a chain other than the target (never in test mode). */
  isWrongNetwork: boolean
  /**
   * Non-null when a transaction submission must be blocked. Safe to feed straight into an
   * action CTA's blockedReason so the confirm button disables and the reason is shown.
   */
  blockedReason: string | null
}

/**
 * Submit-time network gate for action pages — the single source action clients use to
 * hard-block submission until the wallet is on the target chain (the wrong-network banner
 * itself is display-only). Inert in headless/test mode so sandbox flows are unaffected.
 */
export function useActionNetworkGuard(): ActionNetworkGuard {
  // Reads the wagmi-free context (fed by the mounted wallet provider), so the borrow client
  // embedded on the Express home page never drags the wallet SDK onto the guest critical path.
  // Inert when no wallet provider is mounted — a guest can't be on the wrong network.
  const { isWrongNetwork, targetChainName } = useWrongNetworkState()
  return {
    isWrongNetwork,
    blockedReason: isWrongNetwork ? `Switch your wallet to ${targetChainName} to continue.` : null,
  }
}
