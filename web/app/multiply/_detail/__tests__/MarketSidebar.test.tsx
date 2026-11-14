import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { getMultiplyMarketDetail } from "@/app/lib/multiply-detail"
import { MarketSidebar } from "@/app/multiply/_detail"

vi.mock("@/app/lib/multiply-system/multiply-session-context", () => ({
  useMultiplySessionContext: () => ({
    walletId: "demo-wallet",
    state: {
      positions: {
        "demo-wallet:aave-gho": {
          walletId: "demo-wallet",
          marketId: "aave-gho",
          multiplier: 2,
        },
      },
    },
  }),
}))

vi.mock("@/app/components/action-page/responsive-multiply-action", () => ({
  ResponsiveMultiplyAction: (props: { kind: string; initialMultiplier?: string }) => (
    <div data-testid="responsive-multiply-action">
      {props.kind}:{props.initialMultiplier ?? ""}
    </div>
  ),
}))

vi.mock("@/app/borrow/_detail/ui", () => ({
  AboutNewsSection: () => null,
}))

describe("MarketSidebar", () => {
  afterEach(() => {
    cleanup()
  })

  it("opens deleverage without pre-seeding a user-confirmable target", async () => {
    const detail = getMultiplyMarketDetail("aave-gho")
    expect(detail).not.toBeNull()

    render(<MarketSidebar detail={detail!} />)

    await waitFor(() => {
      expect(screen.getByTestId("responsive-multiply-action")).toHaveTextContent("multiply:")
    })

    fireEvent.click(screen.getByRole("tab", { name: "Deleverage" }))

    await waitFor(() => {
      expect(screen.getByTestId("responsive-multiply-action")).toHaveTextContent("deleverage:")
    })

    fireEvent.click(screen.getByRole("tab", { name: "Close" }))

    await waitFor(() => {
      expect(screen.getByTestId("responsive-multiply-action")).toHaveTextContent("close:")
    })
  })
})
