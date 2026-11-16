import { api } from "@/convex/_generated/api"
import { hasConvexClient } from "@/app/lib/convex/has-convex-client"
import { getSiweSession } from "@/app/lib/siwe/auth-store"

/**
 * The referral link and its two halves in the app: a visitor who arrives with `?ref=<code>` keeps the code (the first one
 * wins) until they sign in, when Convex attributes the wallet to the code's owner; and a signed-in wallet reads its own
 * code to build the link it shares. Convex does the checks (own code, new wallet, once); everything here is best effort.
 */

const STORAGE_KEY = "avana.referral.code"
/** The invite code alphabet of Convex `lib/referrals.ts`: 8 characters, no 0, 1, i, l or o. */
const CODE = /^[2-9a-hjkmnp-z]{8}$/

export type AttributionResult = "attributed" | "already" | "self" | "unknown_code" | "not_new"

/** The invite code in a URL query string (`?ref=…`), lower-cased, or null when it is missing or malformed. */
export function referralCodeFromSearch(search: string): string | null {
  const raw = new URLSearchParams(search).get("ref")?.trim().toLowerCase()
  return raw && CODE.test(raw) ? raw : null
}

export function getStoredReferralCode(): string | null {
  try {
    const value = window.localStorage.getItem(STORAGE_KEY)
    return value && CODE.test(value) ? value : null
  } catch {
    return null
  }
}

/** Keeps the code of the first referral link a visitor opened; a later link does not replace it. */
export function storeReferralCode(code: string): void {
  try {
    if (!CODE.test(code) || window.localStorage.getItem(STORAGE_KEY)) return
    window.localStorage.setItem(STORAGE_KEY, code)
  } catch {
    // Storage can be blocked; the referral is then simply not captured.
  }
}

export function clearStoredReferralCode(): void {
  try {
    window.localStorage.removeItem(STORAGE_KEY)
  } catch {
    // Nothing to clear.
  }
}

/** The link a wallet shares: the site's own address with its code. */
export function referralLink(origin: string, code: string): string {
  return `${origin.replace(/\/$/, "")}/?ref=${code}`
}

/**
 * Attributes the signed-in wallet to the owner of `code` (Convex `wallet.referrals.attribute`). Resolves Convex's answer,
 * or null without a session or a deployment and on any failure, in which case the code is kept to try again.
 */
export async function attributeReferral(code: string): Promise<AttributionResult | null> {
  try {
    if (!hasConvexClient) return null
    const session = getSiweSession()
    if (!session) return null
    const { getSiweConvexClient } = await import("@/app/lib/convex/siwe-convex-provider")
    const client = getSiweConvexClient()
    if (!client) return null
    return (await client.mutation(api.wallet.referrals.attribute, { wallet: session.wallet, code })).result
  } catch {
    return null
  }
}

/** The signed-in wallet's own invite code, created on first use (Convex `wallet.referrals.myCode`); null when unavailable. */
export async function fetchMyReferralCode(): Promise<string | null> {
  try {
    if (!hasConvexClient) return null
    const session = getSiweSession()
    if (!session) return null
    const { getSiweConvexClient } = await import("@/app/lib/convex/siwe-convex-provider")
    const client = getSiweConvexClient()
    if (!client) return null
    return (await client.mutation(api.wallet.referrals.myCode, { wallet: session.wallet })).code
  } catch {
    return null
  }
}
