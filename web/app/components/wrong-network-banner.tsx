"use client"

import { useWalletGate } from "@/app/lib/web3/wallet-gate"
import { useWalletSlotRef } from "@/app/lib/web3/wallet-slots"

/**
 * App-wide guard: when the connected wallet is on the wrong chain, a blocking banner appears
 * under the header prompting the user to switch. Actions elsewhere gate on the same
 * `useWrongNetwork()` state, so nothing can be submitted until the wallet is back on the
 * target chain.
 *
 * The banner body reads a wagmi hook, so it is rendered by the wallet SDK runtime (a sibling of
 * the app tree) into this slot via a portal once the SDK is mounted — see `wallet-slots.ts`. A
 * guest with no wallet can't be on the wrong network, so nothing renders until then.
 */
export function WrongNetworkBanner() {
  const { active } = useWalletGate()
  if (!active) return null
  return <WrongNetworkBannerSlot />
}

function WrongNetworkBannerSlot() {
  const ref = useWalletSlotRef("wrong-network-banner")
  return <div ref={ref} className="contents" />
}
