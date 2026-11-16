"use client"

import { useChainLendPositions } from "@/app/lib/lend-system/use-chain-lend-positions"

/** Reads the session wallet's Lend supplies from the chain into the lend session. Renders nothing. */
export function ChainLendPositionsHydrator({ walletId }: { walletId: string }) {
  useChainLendPositions(walletId)
  return null
}
