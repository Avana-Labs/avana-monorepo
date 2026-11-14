import { cleanup, render, screen, waitFor, within } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import {
  UmbrellaMarketRiskMetrics,
  UmbrellaMarketRiskMetricsCard,
} from "@/app/umbrella/_detail/market-sections/UmbrellaStress"
import { buildDefaultUmbrellaState, UMBRELLA_MARKET_ORDER } from "@/app/lib/umbrella-system/use-umbrella-session"

// jsdom does not advance performance.now() inside its rAF loop. Advance the
// timestamp so each mount animation can settle in one frame for deterministic QA.
beforeEach(() => {
  vi.stubGlobal(
    "requestAnimationFrame",
    (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now() + 100000), 0) as unknown as number,
  )
  vi.stubGlobal("cancelAnimationFrame", (id: number) => clearTimeout(id as unknown as ReturnType<typeof setTimeout>))
})

afterEach(() => {
  cleanup()
})

describe("Umbrella action market metrics", () => {
  it("animates the shared metrics for every market used by the 16 action routes", async () => {
    const markets = buildDefaultUmbrellaState("animation-test-wallet").markets

    render(
      <>
        {UMBRELLA_MARKET_ORDER.map((marketId) => (
          <div key={marketId} data-testid={`market-${marketId}`}>
            <UmbrellaMarketRiskMetrics market={markets[marketId]} />
          </div>
        ))}
      </>,
    )

    for (const marketId of UMBRELLA_MARKET_ORDER) {
      expect(within(screen.getByTestId(`market-${marketId}`)).getAllByText("$0.0M").length).toBeGreaterThan(0)
    }

    await waitFor(() => {
      expect(within(screen.getByTestId("market-gho")).getByText("$25.0M")).toBeInTheDocument()
      expect(within(screen.getByTestId("market-usdc")).getByText("$12.0M")).toBeInTheDocument()
      expect(within(screen.getByTestId("market-usdt")).getByText("$9.5M")).toBeInTheDocument()
      expect(within(screen.getByTestId("market-weth")).getByText("$7.0M")).toBeInTheDocument()
    })
  })

  it("shows earned reward dollars instead of APY for post-stake actions", async () => {
    const market = buildDefaultUmbrellaState("earnings-test-wallet").markets.gho

    render(<UmbrellaMarketRiskMetricsCard market={market} showExpandedDetails earnedRewardsUsd={11.4} />)

    expect(screen.getByText("Earnings")).toBeInTheDocument()
    expect(screen.queryByText("6.4%")).not.toBeInTheDocument()
    expect(screen.getByLabelText("Earnings contribution bar")).toBeInTheDocument()
    await waitFor(() => {
      expect(screen.getByText("$11.4")).toBeInTheDocument()
      expect(screen.getByText("$0")).toBeInTheDocument()
      expect(screen.getByText("$4.01")).toBeInTheDocument()
      expect(screen.getByText("$7.39")).toBeInTheDocument()
    })
  })
})
