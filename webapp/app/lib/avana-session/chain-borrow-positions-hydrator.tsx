"use client"

import { useEffect } from "react"
import { setPledgeableLps } from "@/app/lib/borrow-system/chain-refs"
import { pledgeableFromWallet } from "@/app/lib/borrow-system/pledgeable-lps"
import { useChainBorrowPositions } from "@/app/lib/borrow-system/use-chain-borrow-positions"
import { useWalletLpPositions } from "@/app/lib/swap-system/use-convex-wallet-balances"

/**
 * Reads the session wallet's Borrow accounts from the chain into the borrow session, and hands the wallet's LP NFTs
 * that a market accepts to the pledge (the Wallet tab's read). Renders nothing.
 */
export function ChainBorrowPositionsHydrator({ walletId }: { walletId: string }) {
  useChainBorrowPositions(walletId)
  const lps = useWalletLpPositions(walletId)
  useEffect(() => {
    setPledgeableLps(walletId, lps ? pledgeableFromWallet(lps) : null)
  }, [walletId, lps])
  return null
}
