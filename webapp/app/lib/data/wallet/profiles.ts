/** A session identity: an id (the lowercased wallet address, or the guest id) and its address. */
export type WalletIdentity = {
  id: string
  walletAddress: string
}

/** Session id for a visitor with no wallet: empty balances and positions, never persisted. */
export const GUEST_WALLET_ID = "guest-wallet"

const GUEST_IDENTITY: WalletIdentity = {
  id: GUEST_WALLET_ID,
  walletAddress: "0x0000000000000000000000000000000000000000",
}

/**
 * Resolve a session identity. Any value other than the guest id is a wallet ADDRESS, used
 * lowercased (the form Convex scopes wallet data by). Undefined is the guest.
 */
export function resolveWalletIdentity(walletId?: string): WalletIdentity {
  if (!walletId || walletId === GUEST_WALLET_ID) return GUEST_IDENTITY
  const address = walletId.toLowerCase()
  return { id: address, walletAddress: address }
}
