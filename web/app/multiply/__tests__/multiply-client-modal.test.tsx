import { fireEvent, render, screen } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { buildMultiplyPageData } from "@/app/lib/multiply-system/read-model"
import { MultiplyClient } from "@/app/multiply/multiply-client"

const push = vi.fn()

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push }),
  useSearchParams: () => new URLSearchParams(),
}))

// MultiplyClient reads api.multiply.tokenParameters.listTokens for its token maps.
// This test only asserts routing, so stub useQuery to skip the Convex path entirely
// (buildMultiplyPageData falls back to the multiply-sim constants when the arg is null).
vi.mock("convex/react", () => ({
  useQuery: () => undefined,
}))

vi.mock("@/app/lib/avana-session/avana-sessions-provider", () => ({
  // MultiplyClient now renders the live session-backed catalog. The routing
  // assertion below doesn't depend on session content (the markets table is
  // mocked), so a minimal session state is enough.
  useMultiplySessionContext: () => ({
    walletId: "wallet-1",
    state: { markets: {}, positions: {}, now: 0, transactions: [] },
  }),
}))

vi.mock("@/app/multiply/components/explore-loops-markets-table", () => ({
  ExploreLoopsMarketsTable: (props: { onOpenMultiply: (href: string) => void }) => (
    <button type="button" onClick={() => props.onOpenMultiply("/multiply/markets/aave-gho")}>
      open-multiply-action
    </button>
  ),
}))

vi.mock("@/app/multiply/components/multiply-hero", () => ({
  MultiplyHero: () => <div>multiply-hero</div>,
}))

describe("MultiplyClient action routing", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it("routes multiply actions to the shared action page", async () => {
    const pageData = buildMultiplyPageData("wallet-1")

    render(<MultiplyClient pageData={pageData} />)

    fireEvent.click(await screen.findByText("open-multiply-action"))
    expect(push).toHaveBeenCalledWith("/actions/multiply/multiply?market=aave-gho")
  })
})
