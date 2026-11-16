"use client"

import { useChainBorrowPositions } from "@/app/lib/borrow-system/use-chain-borrow-positions"

/** Reads the session wallet's Borrow accounts from the chain into the borrow session. Renders nothing. */
export function ChainBorrowPositionsHydrator({ walletId }: { walletId: string }) {
  useChainBorrowPositions(walletId)
  return null
}
