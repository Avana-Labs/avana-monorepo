"use client"

import type { SIWEConfig } from "connectkit"
import { buildSiweMessage } from "./message"
import { clearSiweToken, getSiweSession, setSiweSession } from "./auth-store"

/**
 * ConnectKit SIWE configuration. This unifies wallet connection and Sign-In With
 * Ethereum into a single ConnectKit flow: the modal connects the wallet, prompts the
 * SIWE signature, and only then reports "signed in". It is wired to the app's existing
 * SIWE endpoints establish an HttpOnly browser session. Convex access tokens are
 * minted on demand and retained only in memory.
 */
export const siweConfig: SIWEConfig = {
  getNonce: async () => {
    const res = await fetch("/api/siwe/nonce", { cache: "no-store" })
    if (!res.ok) throw new Error("Could not get a sign-in nonce.")
    const { nonce } = (await res.json()) as { nonce: string }
    return nonce
  },

  createMessage: ({ nonce, address, chainId }) =>
    buildSiweMessage({
      address,
      domain: window.location.host,
      uri: window.location.origin,
      nonce,
      issuedAt: new Date().toISOString(),
      chainId,
    }),

  verifyMessage: async ({ message, signature }) => {
    const res = await fetch("/api/siwe/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ message, signature }),
    })
    if (!res.ok) return false
    const { wallet } = (await res.json()) as { wallet: string }
    setSiweSession(wallet)
    return true
  },

  // ConnectKit polls this to know whether the wallet is already signed in. The root
  // layout hydrates this non-secret wallet metadata from the HttpOnly session.
  getSession: async () => {
    const session = getSiweSession()
    if (!session?.wallet) return null
    return { address: session.wallet as `0x${string}`, chainId: 1 }
  },

  signOut: async () => {
    try {
      await fetch("/api/siwe/logout", { method: "POST" })
    } finally {
      clearSiweToken()
    }
    return true
  },
}
