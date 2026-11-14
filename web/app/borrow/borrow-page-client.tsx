"use client"

import { BorrowPageHero } from "./borrow-page-hero"
import { BorrowWorkspaceShell } from "./borrow-workspace-shell"
import { useAvanaIdentity } from "@/app/lib/avana-session/avana-sessions-provider"
import type { BorrowPageData, BorrowWorkspaceData } from "@/app/lib/data/providers/borrow"

export function BorrowPageClient({
  pageData,
  initialIsDesktop,
}: {
  pageData: BorrowPageData
  initialIsDesktop: boolean
}) {
  const { walletId } = useAvanaIdentity()

  // Render the server-provided (live Convex) page data directly — no client-side
  // re-derivation that swaps it after mount (that was the flicker). The workspace
  // reads the wallet's own live positions from the borrow session internally.
  const workspaceData: BorrowWorkspaceData = {
    walletId,
    borrowSessionSeed: pageData.borrowSessionSeed,
    poolCatalog: pageData.poolCatalog,
    borrowableAssets: pageData.borrowableAssets,
    pendingRows: pageData.pendingRows,
    dexes: pageData.dexes,
    collateralPools: pageData.collateralPools,
    initialDebts: pageData.initialDebts,
    borrowSnapshot: pageData.borrowSnapshot,
  }

  return (
    <>
      <BorrowPageHero pageData={pageData} />
      <BorrowWorkspaceShell pageData={workspaceData} initialIsDesktop={initialIsDesktop} />
    </>
  )
}
