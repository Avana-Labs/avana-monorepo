"use client"

import type { BorrowWorkspaceData } from "@/app/lib/data/providers/borrow"
import { BorrowWorkspace } from "./components/borrow-workspace"

export function BorrowWorkspaceShell({
  pageData,
  initialIsDesktop,
}: {
  pageData: BorrowWorkspaceData
  initialIsDesktop: boolean
}) {
  return (
    <div className="borrow-workspace-shell min-h-[320px]">
      <BorrowWorkspace pageData={pageData} initialIsDesktop={initialIsDesktop} />
    </div>
  )
}
