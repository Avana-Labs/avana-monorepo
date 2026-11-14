/**
 * Canonical open-gate / seed wallet address. Must match TEST_MODE_WALLET_ADDRESS
 * in app/lib/test-mode.ts so seeded debts/collateral/claims hydrate into the
 * same Convex wallet the open-gate JWT authenticates as.
 *
 * Production wallets never collide: they are distinct 0x addresses controlled
 * by real SIWE subjects.
 */
export const TEST_WALLET_ADDRESS = "0x0000000000000000000000000000000000000a11"
