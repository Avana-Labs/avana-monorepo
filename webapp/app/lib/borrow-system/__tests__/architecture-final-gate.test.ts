import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import path from "node:path"

const actionSurfaces = [
  "app/components/home-page-client.tsx",
  "app/borrow/_detail/sidebars/PoolBorrowSidebar.tsx",
  "app/borrow/_detail/sidebars/AssetTokenSidebar.tsx",
  "app/dashboard/dashboard-borrow-tab.tsx",
]

const legacyPreviewFunctions = [
  "buildBorrowPreview(",
  "buildRepayPreview(",
  "buildRemovePreview(",
  "calculateRepayPreview(",
  "calculateRemovePreview(",
  "calculateClaimPreview(",
]

const legacyModalFiles = [
  "app/borrow/components/borrow-modal.tsx",
  "app/borrow/components/repay-remove-modal.tsx",
  "app/borrow/components/supply-collateral-modal.tsx",
  "app/lend/components/lend-market-action-dialog.tsx",
]

describe("borrow architecture final gate", () => {
  it("removes legacy home-sim preview math from action surfaces", () => {
    const offenders = actionSurfaces.filter((file) => {
      const source = readFileSync(path.join(process.cwd(), file), "utf8")
      return legacyPreviewFunctions.some((symbol) => source.includes(symbol))
    })

    expect(offenders).toEqual([])
  })

  it("removes legacy modal components from the repo", () => {
    const offenders = legacyModalFiles.filter((file) => {
      try {
        readFileSync(path.join(process.cwd(), file), "utf8")
        return true
      } catch {
        return false
      }
    })

    expect(offenders).toEqual([])
  })

  it("routes borrow surfaces through action page launch CTAs", () => {
    const homeSource = readFileSync(path.join(process.cwd(), "app/components/home-page-workspace-runtime.tsx"), "utf8")
    expect(homeSource).toContain("BorrowActionPageClient")
    expect(homeSource).toContain("embedded")
    expect(homeSource).not.toContain("EmbeddedActionPage")
    // Asset details (/borrow/assets) are scoped to Borrow + Repay only — the Lend/Withdraw
    // tabs (and ResponsiveLendAction) were intentionally removed in aa8b4269 ("scope
    // detail-page actions to two correct buttons"), so only ResponsiveBorrowAction is expected here.
    expect(
      readFileSync(path.join(process.cwd(), "app/borrow/_detail/sidebars/AssetTokenSidebar.tsx"), "utf8"),
    ).toContain("ResponsiveBorrowAction")
    expect(readFileSync(path.join(process.cwd(), "app/dashboard/dashboard-borrow-tab.tsx"), "utf8")).toContain(
      "actionPagePath",
    )
    expect(
      readFileSync(path.join(process.cwd(), "app/borrow/_detail/sidebars/PoolBorrowSidebar.tsx"), "utf8"),
    ).toContain("ResponsiveBorrowAction")
    expect(
      readFileSync(path.join(process.cwd(), "app/borrow/_detail/sidebars/PoolBorrowSidebar.tsx"), "utf8"),
    ).toContain("embedActions")
    const poolSidebarSource = readFileSync(
      path.join(process.cwd(), "app/borrow/_detail/sidebars/PoolBorrowSidebar.tsx"),
      "utf8",
    )
    expect(poolSidebarSource).toMatch(/PoolBorrowActions[\s\S]*ActionPageLaunchCta/)
  })
})
