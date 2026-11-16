"use client"

import { useChainBorrowPositions } from "@/app/lib/borrow-system/use-chain-borrow-positions"
import { useLendHubAssetRefs } from "@/app/lib/lend-system/chain-lend-refs"

/**
 * Reads the session wallet's Borrow accounts from the chain into the borrow session, and keeps the Hub assets' lend
 * reserves for a Lend send. Renders nothing.
 */
export function ChainBorrowPositionsHydrator({ walletId }: { walletId: string }) {
  useChainBorrowPositions(walletId)
  useLendHubAssetRefs()
  return null
}
