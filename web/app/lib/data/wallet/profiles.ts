import type { PortfolioWalletProfileRecord } from "@/app/lib/data/providers/portfolio/source"

/** Session id for a visitor with no wallet: empty balances and positions, never persisted. */
export const GUEST_WALLET_ID = "guest-wallet"

export const WALLET_PROFILES: PortfolioWalletProfileRecord[] = [
  {
    id: "demo-wallet",
    walletAddress: "0x4b9815d5a010bee5ef34ee531a7ae15667fd7acc",
  },
  // The home "Express" workspace runs on its own wallet so its sandbox session is
  // isolated from the seeded demo portfolio (no inherited debt, separate
  // localStorage). buildMockBorrowSystemState special-cases this id to seed a
  // neutral, debt-free state. Keep it OUT of index 0 so the default profile and
  // the dashboard/borrow pages still resolve to "demo-wallet".
  {
    id: "home-demo-wallet",
    walletAddress: "0x000000000000000000000000000000000000ad0e",
  },
  {
    id: GUEST_WALLET_ID,
    walletAddress: "0x0000000000000000000000000000000000000000",
  },
]

export function getWalletProfile(walletProfileId: string) {
  return WALLET_PROFILES.find((profile) => profile.id === walletProfileId) ?? WALLET_PROFILES[0]
}

export function getDefaultWalletProfileId() {
  return WALLET_PROFILES[0]?.id ?? "demo-wallet"
}

/** True when the id is a built-in demo/home profile (not a real, authed address). */
export function isKnownWalletProfileId(walletProfileId: string) {
  return WALLET_PROFILES.some((profile) => profile.id === walletProfileId)
}

/**
 * Resolve a session identity. A built-in profile id maps to its mock address; ANY
 * other value is treated as a real (authed) wallet ADDRESS and used directly,
 * lowercased to match Convex wallet scoping (convex/sandbox/auth.ts). Undefined falls
 * back to the default demo profile so the public, unauthenticated demo is unchanged.
 */
export function resolveWalletIdentity(walletId?: string): PortfolioWalletProfileRecord {
  if (!walletId) return getWalletProfile(getDefaultWalletProfileId())
  const known = WALLET_PROFILES.find((profile) => profile.id === walletId)
  if (known) return known
  const address = walletId.toLowerCase()
  return { id: address, walletAddress: address }
}
