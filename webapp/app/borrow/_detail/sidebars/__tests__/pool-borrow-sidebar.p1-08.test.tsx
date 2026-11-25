import { render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { PoolBorrowActions } from "@/app/borrow/_detail/sidebars/PoolBorrowSidebar"

vi.mock("@/app/lib/avana-session/avana-sessions-provider", () => ({
  useBorrowSessionContext: () => ({ collateralPools: [] }),
}))

vi.mock("@/app/lib/i18n/use-translation", () => ({
  useTranslation: () => ({ t: (value: string) => value }),
}))

vi.mock("@/app/components/action-page/action-page-launch-cta", () => ({
  ActionPageLaunchCta: ({ kind }: { kind: string }) => <div>launch:{kind}</div>,
}))

const detail = {
  id: "uni-v3-bluechip-weth-usdc",
  hero: {
    name: "WETH / USDC",
    venue: "Uniswap v3",
    feeTier: "0.3%",
    visuals: [
      { symbol: "WETH", shortLabel: "W", bgClass: "bg-black", textClass: "text-white" },
      { symbol: "USDC", shortLabel: "U", bgClass: "bg-blue-500", textClass: "text-white" },
    ],
  },
  row: { collateralExampleUsd: 1000, ltv: 76.5, aprMin: 4, aprMax: 7 },
} as never

describe("PoolBorrowSidebar", () => {
  it("a collateral-pool detail exposes Pledge, Remove, and Claim (not Borrow/Repay)", () => {
    render(<PoolBorrowActions detail={detail} />)
    expect(screen.getByRole("tab", { name: "Pledge" })).toBeInTheDocument()
    expect(screen.getByRole("tab", { name: "Remove" })).toBeInTheDocument()
    expect(screen.getByRole("tab", { name: "Claim" })).toBeInTheDocument()
    expect(screen.queryByRole("tab", { name: "Borrow" })).not.toBeInTheDocument()
    expect(screen.queryByRole("tab", { name: "Repay" })).not.toBeInTheDocument()
  })
})
