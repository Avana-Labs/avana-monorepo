import { cleanup, render } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

const navigation = vi.hoisted(() => ({ pathname: "/ask" }))

vi.mock("next/navigation", () => ({
  usePathname: () => navigation.pathname,
}))

vi.mock("@/app/lib/i18n/use-translation", () => ({
  useTranslation: () => ({ t: (key: string) => key, language: "en" }),
}))

import { RouteContentSkeleton } from "@/app/components/loading-states"

describe("Focused route loading", () => {
  afterEach(cleanup)

  beforeEach(() => {
    navigation.pathname = "/ask"
  })

  it.each(["/ask", "/actions/borrow/borrow"])(
    "does not render the generic product skeleton before %s initializes",
    (pathname) => {
      navigation.pathname = pathname
      const { container } = render(<RouteContentSkeleton />)

      expect(container.querySelector('[data-testid="focused-route-pending"]')).toBeInTheDocument()
      expect(container.querySelector(".skeleton-shimmer")).toBeNull()
    },
  )

  it.each([
    ["/borrow", "borrow-page-skeleton"],
    ["/lend", "lend-page-skeleton"],
    ["/borrow/markets/uni-v3-bluechip-weth-usdt", "borrow-pool-detail-skeleton"],
    ["/borrow/assets/usdc", "borrow-asset-detail-skeleton"],
    ["/lend/markets/eth", "lend-market-detail-skeleton"],
  ])("renders the bespoke %s loading layout", (pathname, testId) => {
    navigation.pathname = pathname
    const { getByTestId, queryByTestId } = render(<RouteContentSkeleton />)

    expect(getByTestId(testId)).toBeInTheDocument()
    expect(queryByTestId("product-route-pending")).not.toBeInTheDocument()
  })
})
