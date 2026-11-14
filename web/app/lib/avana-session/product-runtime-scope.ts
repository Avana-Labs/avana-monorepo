"use client"

/**
 * Which Convex session/market subscriptions a signed-in route should open.
 * Product pages stay at ≤3 session-provider subscriptions; cross-product remotes
 * (rewards / swap / umbrella) only mount on their own surfaces (or dashboard).
 */
export type ProductRuntimeScope = {
  /** Wallet session + product-balance hydration (borrow/lend/swap/home). */
  walletSession: boolean
  /** Public market snapshot hydrate for borrow / lend markets. */
  marketSnapshots: boolean
  hydrateBorrowMarkets: boolean
  hydrateLendMarkets: boolean
  swapTransactions: boolean
  rewards: boolean
  umbrella: boolean
  ensureUmbrellaFixtures: boolean
}

const IDLE: ProductRuntimeScope = {
  walletSession: false,
  marketSnapshots: false,
  hydrateBorrowMarkets: false,
  hydrateLendMarkets: false,
  swapTransactions: false,
  rewards: false,
  umbrella: false,
  ensureUmbrellaFixtures: false,
}

function pathPrefix(pathname: string, route: string) {
  return pathname === route || pathname.startsWith(`${route}/`)
}

/** Resolve subscription scope from the current pathname (no hooks — easy to unit test). */
export function resolveProductRuntimeScope(pathname: string | null | undefined): ProductRuntimeScope {
  if (!pathname) return IDLE

  if (pathPrefix(pathname, "/borrow") || pathPrefix(pathname, "/actions/borrow")) {
    return {
      ...IDLE,
      walletSession: true,
      marketSnapshots: true,
      hydrateBorrowMarkets: true,
    }
  }

  if (pathPrefix(pathname, "/lend") || pathPrefix(pathname, "/actions/lend")) {
    return {
      ...IDLE,
      walletSession: true,
      marketSnapshots: true,
      hydrateLendMarkets: true,
    }
  }

  if (pathPrefix(pathname, "/swap") || pathPrefix(pathname, "/actions/swap")) {
    return {
      ...IDLE,
      walletSession: true,
      swapTransactions: true,
    }
  }

  if (pathPrefix(pathname, "/umbrella") || pathPrefix(pathname, "/actions/umbrella")) {
    return {
      ...IDLE,
      umbrella: true,
      ensureUmbrellaFixtures: true,
    }
  }

  if (pathPrefix(pathname, "/dashboard")) {
    // Consolidated portfolio surface: hydrate the Borrow/Lend sessions plus rewards/umbrella remotes.
    // Borrow markets too: without the live LP price the Borrow tab valued collateral at the
    // catalog estimate (cbBTC/USDC $37.5K vs $48.6K elsewhere). Swap history remains off here.
    return {
      ...IDLE,
      walletSession: true,
      marketSnapshots: true,
      hydrateBorrowMarkets: true,
      rewards: true,
      umbrella: true,
      ensureUmbrellaFixtures: true,
    }
  }

  // Signed-in home workspace embeds borrow + swap.
  if (pathname === "/") {
    return {
      ...IDLE,
      walletSession: true,
      marketSnapshots: true,
      hydrateBorrowMarkets: true,
      swapTransactions: true,
    }
  }

  if (pathPrefix(pathname, "/onboarding") || pathPrefix(pathname, "/sandbox")) {
    return {
      ...IDLE,
      walletSession: true,
      ensureUmbrellaFixtures: true,
    }
  }

  return IDLE
}
