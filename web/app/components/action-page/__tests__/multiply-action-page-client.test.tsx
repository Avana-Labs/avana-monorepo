import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import type { ReactNode } from "react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { DisplayPreferencesProvider } from "@/app/components/display-preferences"
import { AvanaSessionsProvider } from "@/app/lib/avana-session/avana-sessions-provider"
import { MultiplyActionPageClient } from "@/app/components/action-page/multiply-action-page-client"
import { TokenPricesContext } from "@/app/lib/prices/token-prices-context"
import { PRICE_FIXTURE } from "@/app/lib/prices/price-fixture"

// The action client now consults wagmi (via useWrongNetwork) to gate submission; stub the two
// hooks the guard uses so these no-WagmiProvider unit tests render (disconnected → not blocked).
vi.mock("wagmi", () => ({
  useAccount: () => ({ isConnected: false, chainId: undefined }),
  useSwitchChain: () => ({ switchChainAsync: vi.fn(), isPending: false }),
}))
import {
  buildMockMultiplySystemState,
  buildMockMultiplySystemStateWithSeedPosition,
} from "@/app/lib/multiply-system/mock"
import {
  readMultiplySessionState,
  writeMultiplySessionMetadata,
  writeMultiplySessionState,
} from "@/app/lib/multiply-system/storage"
import { serializeMultiplySystemState } from "@/app/lib/multiply-system/codec"

const TEST_PRICES = Object.fromEntries(
  Object.entries(PRICE_FIXTURE).map(([symbol, price]) => [symbol.toLowerCase(), price]),
)
const renderWithProviders = (ui: ReactNode) =>
  render(
    <TokenPricesContext.Provider value={TEST_PRICES}>
      <DisplayPreferencesProvider>{ui}</DisplayPreferencesProvider>
    </TokenPricesContext.Provider>,
  )
const DEMO_WALLET_ID = "demo-wallet"

function seedExistingMultiplyPosition() {
  const state = buildMockMultiplySystemStateWithSeedPosition(DEMO_WALLET_ID)
  state.walletBalancesUsd[DEMO_WALLET_ID] = {
    ...(state.walletBalancesUsd[DEMO_WALLET_ID] ?? {}),
    "eth-usdt": 12_500,
  }
  writeMultiplySessionState(DEMO_WALLET_ID, state)
  writeMultiplySessionMetadata(DEMO_WALLET_ID, {
    transactionHistory: [
      {
        id: "seeded-position-history",
        intentId: "seeded-position-intent",
        walletId: DEMO_WALLET_ID,
        marketId: "eth-usdt",
        kind: "multiply",
        status: "success",
        amountUsd: 3500,
        multiplierBefore: 1,
        multiplierAfter: 2,
        simulated: true,
        timestamp: state.now,
        hash: "sim-seeded-position",
      },
    ],
    receipts: [],
  })
}

function seedMultiplyWalletBalances() {
  const state = buildMockMultiplySystemState(DEMO_WALLET_ID)
  state.walletBalancesUsd[DEMO_WALLET_ID] = {
    "eth-usdt": 12_500,
    "aave-gho": 12_500,
  }
  writeMultiplySessionState(DEMO_WALLET_ID, state)
}

describe("MultiplyActionPageClient", () => {
  beforeEach(() => {
    window.localStorage.clear()
    seedMultiplyWalletBalances()
  })

  afterEach(() => {
    cleanup()
  })

  it("does not show transaction preview metrics before a multiply amount is entered", async () => {
    renderWithProviders(
      <AvanaSessionsProvider>
        <MultiplyActionPageClient kind="multiply" />
      </AvanaSessionsProvider>,
    )

    await waitFor(() => {
      expect(screen.getByTestId("action-amount-card")).toBeInTheDocument()
    })

    expect(screen.queryByTestId("action-metrics-block")).not.toBeInTheDocument()
    expect(screen.queryByTestId("action-risk-banner")).not.toBeInTheDocument()
    expect(screen.getByText("$0.00")).toBeInTheDocument()
    expect(screen.getByText("1.1x")).toBeInTheDocument()
  })

  it("keeps an above-public-max multiplier on the global 1–9.99 slider", async () => {
    renderWithProviders(
      <AvanaSessionsProvider>
        <MultiplyActionPageClient kind="multiply" initialMarketId="aave-gho" initialMultiplier="9.99" />
      </AvanaSessionsProvider>,
    )

    const slider = (await screen.findByRole("slider", { name: "Multiplier" })) as HTMLInputElement
    await waitFor(() => expect(slider.value).toBe("9.99"))
    expect(screen.getByTestId("action-leverage-pill")).toHaveTextContent("9.99x")
    expect(screen.getByTestId("action-leverage-ticks")).toHaveTextContent("9.99x")
  })

  it("previews a fresh-wallet multiply without merging a ghost position", async () => {
    renderWithProviders(
      <AvanaSessionsProvider>
        <MultiplyActionPageClient kind="multiply" initialMarketId="eth-usdt" initialMultiplier="2" />
      </AvanaSessionsProvider>,
    )

    fireEvent.change(screen.getByLabelText("Collateral amount"), { target: { value: "0.01" } })

    await waitFor(() => expect(screen.getByTestId("action-metrics-block")).toBeInTheDocument())
    expect(screen.getByLabelText("Collateral amount")).toHaveValue("0.01")
    expect(screen.getByTestId("action-leverage-ruler")).toHaveTextContent("Multiplier")
    expect(screen.queryByText(/loop.*estimated/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/Recommended up to/i)).not.toBeInTheDocument()
    expect(screen.getByTestId("action-metrics-block")).toHaveTextContent("Collateral")
    expect(screen.getByTestId("action-metrics-block")).toHaveTextContent("Target leverage")
    expect(screen.getByTestId("action-metrics-block")).toHaveTextContent("Looped exposure")
    expect(screen.getByTestId("action-metrics-block")).toHaveTextContent("USDT borrowed")
    expect(screen.getByTestId("action-metrics-block")).toHaveTextContent("Borrow capacity remaining")
    expect(screen.getByTestId("action-metrics-block")).not.toHaveTextContent("Projected exposure")
    expect(screen.queryByText(/0\.01.*2\.00x/)).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Review" }))

    await waitFor(() => expect(screen.getByTestId("action-review-stage")).toBeInTheDocument())
    expect(screen.getByTestId("action-review-stage")).toHaveTextContent("Collateral")
    expect(screen.getByTestId("action-review-stage")).toHaveTextContent("0.01")
    expect(screen.getByTestId("action-review-stage")).toHaveTextContent("Target leverage")
    expect(screen.queryByText(/0\.01.*2\.00x/)).not.toBeInTheDocument()
  })

  it("blocks a leverage open when Convex has no validated collateral quote", async () => {
    render(
      <TokenPricesContext.Provider value={{}}>
        <DisplayPreferencesProvider>
          <AvanaSessionsProvider>
            <MultiplyActionPageClient kind="multiply" initialMarketId="eth-usdt" initialMultiplier="2" />
          </AvanaSessionsProvider>
        </DisplayPreferencesProvider>
      </TokenPricesContext.Provider>,
    )

    fireEvent.change(screen.getByLabelText("Collateral amount"), { target: { value: "0.01" } })

    await waitFor(() => expect(screen.getByText(/Collateral price is stale/)).toBeInTheDocument())
    expect(screen.getByRole("button", { name: /price/i })).toBeDisabled()
  })

  it("rejects an absurd collateral amount and blocks Review", async () => {
    renderWithProviders(
      <AvanaSessionsProvider>
        <MultiplyActionPageClient kind="multiply" initialMarketId="eth-usdt" initialMultiplier="2" />
      </AvanaSessionsProvider>,
    )

    const input = await screen.findByLabelText("Collateral amount")
    fireEvent.change(input, { target: { value: "999999999" } })

    // No crash, no projected metrics. The block lives on the CTA itself: it is
    // disabled and names the shortfall ("Insufficient ETH") instead of "Review".
    await waitFor(() => expect(screen.getByRole("button", { name: "Insufficient ETH" })).toBeInTheDocument())
    expect(screen.queryByTestId("action-metrics-block")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Review" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Insufficient ETH" })).toBeDisabled()

    // A within-cap amount is accepted and produces a live preview.
    fireEvent.change(input, { target: { value: "0.01" } })
    await waitFor(() => expect(screen.getByTestId("action-metrics-block")).toBeInTheDocument())
    expect(screen.queryByRole("button", { name: "Insufficient ETH" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Review" })).not.toBeDisabled()
  })

  it("fills the collateral input with the wallet-balance cap via Max", async () => {
    renderWithProviders(
      <AvanaSessionsProvider>
        <MultiplyActionPageClient kind="multiply" initialMarketId="eth-usdt" initialMultiplier="2" />
      </AvanaSessionsProvider>,
    )

    const input = (await screen.findByLabelText("Collateral amount")) as HTMLInputElement
    // Scope to the amount card's balance shortcut (clicking the balance fills the
    // balance-cap amount), distinct from the leverage ruler below it.
    const amountCard = within(screen.getByTestId("action-amount-card"))
    fireEvent.click(amountCard.getByRole("button", { name: /Available to loop:/ }))

    // Max fills the wallet's spendable balance ($12,500 budget / ETH price), not the
    // pool's multi-million liquidity; the filled value must be within the cap so it
    // is not itself rejected.
    await waitFor(() => expect(input.value).not.toBe(""))
    expect(Number(input.value)).toBeGreaterThan(0)
    expect(screen.queryByText(/exceeds your available balance/i)).not.toBeInTheDocument()
  })

  it("keeps deleverage preview blank until the target multiplier changes", async () => {
    seedExistingMultiplyPosition()
    renderWithProviders(
      <AvanaSessionsProvider>
        <MultiplyActionPageClient kind="deleverage" initialMarketId="eth-usdt" />
      </AvanaSessionsProvider>,
    )

    await waitFor(() => {
      expect(screen.getByRole("slider", { name: "Target leverage" })).toBeInTheDocument()
    })

    expect(screen.getByRole("slider", { name: "Target leverage" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Enter an amount" })).toBeDisabled()
    expect(screen.queryByTestId("action-metrics-block")).not.toBeInTheDocument()
    expect(screen.queryByTestId("action-risk-banner")).not.toBeInTheDocument()
  })

  it("shows a disabled 1x target and no-position CTA without an active position", async () => {
    renderWithProviders(
      <AvanaSessionsProvider>
        <MultiplyActionPageClient kind="deleverage" />
      </AvanaSessionsProvider>,
    )

    await waitFor(() => expect(screen.getByRole("slider", { name: "Target leverage" })).toBeInTheDocument())
    expect(screen.getByRole("slider", { name: "Target leverage" })).toHaveValue("1")
    expect(screen.getByRole("button", { name: "No position" })).toBeDisabled()
  })

  it("shows an explicit no-position state on the direct close route", async () => {
    renderWithProviders(
      <AvanaSessionsProvider>
        <MultiplyActionPageClient kind="close" initialMarketId="eth-usdt" />
      </AvanaSessionsProvider>,
    )

    await waitFor(() => expect(screen.getByRole("button", { name: "No position" })).toBeInTheDocument())
    expect(screen.getByText("No open position to close in this market.")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Enter an amount" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "No position" })).toBeDisabled()
  })

  it("keeps embedded deleverage preview blank while showing the default target multiplier", async () => {
    seedExistingMultiplyPosition()
    renderWithProviders(
      <AvanaSessionsProvider>
        <MultiplyActionPageClient kind="deleverage" embedded layout="home" initialMarketId="aave-gho" />
      </AvanaSessionsProvider>,
    )

    await waitFor(() => {
      expect(screen.getByRole("slider", { name: "Target leverage" })).toBeInTheDocument()
    })

    expect(screen.getByTestId("action-leverage-ruler")).toBeInTheDocument()
    // The seeded position lives in eth-usdt while this renders aave-gho. The exit routes now
    // fall back to a market the wallet can actually exit instead of dead-ending on
    // "No position", so the CTA is no longer the blocked no-position label.
    expect(screen.queryByRole("button", { name: "No position" })).not.toBeInTheDocument()
    expect(screen.queryByTestId("action-health-factor-card")).not.toBeInTheDocument()
    expect(screen.queryByTestId("action-metrics-block")).not.toBeInTheDocument()
  })

  it("falls back to a market holding a position instead of dead-ending on close", async () => {
    // Regression: /actions/multiply/close?market=<market with no position> rendered
    // "No open position to close in this market." with no collateral field and no way to
    // switch. Exit kinds now resolve a market the wallet can exit and expose the picker.
    seedExistingMultiplyPosition()
    renderWithProviders(
      <AvanaSessionsProvider>
        <MultiplyActionPageClient kind="close" initialMarketId="aave-gho" />
      </AvanaSessionsProvider>,
    )

    await waitFor(() => {
      expect(screen.queryByText("No open position to close in this market.")).not.toBeInTheDocument()
    })
    expect(screen.queryByRole("button", { name: "No position" })).not.toBeInTheDocument()
  })

  it("lets the deleverage slider move freely instead of snapping back to the default", async () => {
    seedExistingMultiplyPosition()
    renderWithProviders(
      <AvanaSessionsProvider>
        <MultiplyActionPageClient kind="deleverage" initialMarketId="eth-usdt" />
      </AvanaSessionsProvider>,
    )

    await screen.findByTestId("action-leverage-ruler")
    // Assert the controlled slider's own value (the state that drives the preview and
    // submission) rather than the animated headline text, which lags during transitions.
    const slider = screen.getByRole("slider", { name: "Target leverage" }) as HTMLInputElement
    // The 2.0x seed position defaults the target to max(1, 2 - 0.5) = 1.5x once.
    await waitFor(() => expect(slider.value).toBe("1.5"))

    // A mid-range value must persist. The frozen slider snapped every drag back to 1.5.
    fireEvent.change(slider, { target: { value: "1.2" } })
    await waitFor(() => expect(slider.value).toBe("1.2"))

    // Another value (both directions) also sticks.
    fireEvent.change(slider, { target: { value: "1.7" } })
    await waitFor(() => expect(slider.value).toBe("1.7"))

    // Dragging to the min (→ 1x) is honored too.
    fireEvent.change(slider, { target: { value: "1" } })
    await waitFor(() => expect(slider.value).toBe("1"))
  })

  it("uses the ruler max to produce a valid deleverage preview", async () => {
    seedExistingMultiplyPosition()
    renderWithProviders(
      <AvanaSessionsProvider>
        <MultiplyActionPageClient kind="deleverage" initialMarketId="eth-usdt" />
      </AvanaSessionsProvider>,
    )

    // Drag the ruler to its max reachable target (just below the 2.0x seed) to
    // produce a valid deleverage preview.
    const slider = await screen.findByRole("slider", { name: "Target leverage" })
    fireEvent.change(slider, { target: { value: "1.9" } })

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Review" })).toBeInTheDocument()
    })

    fireEvent.click(screen.getByRole("button", { name: "Review" }))

    fireEvent.click(screen.getByRole("button", { name: "Deleverage" }))

    await waitFor(
      () => {
        expect(screen.getByText("Deleverage successful")).toBeInTheDocument()
      },
      { timeout: 8000 },
    )
  })

  it("fully closes a position from the deleverage view and removes it from state", async () => {
    seedExistingMultiplyPosition()
    renderWithProviders(
      <AvanaSessionsProvider>
        <MultiplyActionPageClient kind="deleverage" initialMarketId="eth-usdt" />
      </AvanaSessionsProvider>,
    )

    const closeButton = await screen.findByTestId("multiply-close-position")
    fireEvent.click(closeButton)

    await waitFor(
      () => {
        expect(screen.getByText("Position closed")).toBeInTheDocument()
      },
      { timeout: 8000 },
    )

    // The closed position is gone from the persisted session state (no zombie left).
    // The write to localStorage flushes shortly AFTER the "Position closed" stage renders,
    // so poll until it lands instead of reading once — a single synchronous read races the
    // async persist and flakes under load.
    await waitFor(() => {
      const persisted = readMultiplySessionState(
        DEMO_WALLET_ID,
        serializeMultiplySystemState({ now: 0, markets: {}, positions: {}, transactions: [] }),
      )
      expect(persisted.positions[`${DEMO_WALLET_ID}:eth-usdt`]).toBeUndefined()
    })
  })

  it("E2: opening at a safe recommended leverage remains allowed", async () => {
    renderWithProviders(
      <AvanaSessionsProvider>
        <MultiplyActionPageClient kind="multiply" initialMarketId="aave-gho" initialMultiplier="1.7" />
      </AvanaSessionsProvider>,
    )

    const input = await screen.findByLabelText("Collateral amount")
    fireEvent.change(input, { target: { value: "5" } })

    expect(screen.queryByText(/Recommended up to/i)).not.toBeInTheDocument()
    // At a safe recommended leverage the action is allowed (Review is offered, not blocked).
    await waitFor(() => expect(screen.getByRole("button", { name: "Review" })).toBeInTheDocument())
    expect(screen.getByRole("button", { name: "Review" })).not.toBeDisabled()
    expect(screen.queryByText(/health factor is below the market minimum/i)).not.toBeInTheDocument()
  })

  it("E2: the public max (above the recommended cap) is still blocked on min health factor", async () => {
    renderWithProviders(
      <AvanaSessionsProvider>
        <MultiplyActionPageClient kind="multiply" initialMarketId="aave-gho" initialMultiplier="1.8" />
      </AvanaSessionsProvider>,
    )

    const input = await screen.findByLabelText("Collateral amount")
    fireEvent.change(input, { target: { value: "5" } })

    // 1.8x → HF ≈ 1.46 < 1.5, so it must NOT offer Review.
    await waitFor(() => expect(screen.queryByRole("button", { name: "Review" })).not.toBeInTheDocument())
  })

  it("E6: dragging the slider keeps 0.01 precision on the pill", async () => {
    renderWithProviders(
      <AvanaSessionsProvider>
        <MultiplyActionPageClient kind="multiply" initialMarketId="eth-usdt" initialMultiplier="2" />
      </AvanaSessionsProvider>,
    )

    const slider = (await screen.findByRole("slider", { name: "Multiplier" })) as HTMLInputElement
    fireEvent.change(slider, { target: { value: "1.75" } })

    await waitFor(() => expect(slider.value).toBe("1.75"))
    expect(screen.getByTestId("action-leverage-pill")).toHaveTextContent("1.75x")
  })

  it("blocks Review when leverage is above the market public maximum", async () => {
    renderWithProviders(
      <AvanaSessionsProvider>
        <MultiplyActionPageClient kind="multiply" initialMarketId="aave-gho" initialMultiplier="5" />
      </AvanaSessionsProvider>,
    )

    const input = await screen.findByLabelText("Collateral amount")
    fireEvent.change(input, { target: { value: "5" } })

    // aave-gho publicMax is 1.8x — 5x is on the global slider but hard-blocked by validation.
    await waitFor(() => expect(screen.queryByRole("button", { name: "Review" })).not.toBeInTheDocument())
    expect(screen.getByRole("slider", { name: "Multiplier" })).toHaveValue("5")
  })

  it("E4: Net APY uses live supply APY and the Collateral/Borrow APY card is gone", async () => {
    // Diverge the live supply APY from the seed collateralAsset.apy (the post-Convex-
    // hydration case) so Net APY must read economics.supplyApy, not the stale seed.
    const state = buildMockMultiplySystemState(DEMO_WALLET_ID)
    state.walletBalancesUsd[DEMO_WALLET_ID] = { "aave-gho": 12_500 }
    const aave = state.markets["aave-gho"]!
    state.markets["aave-gho"] = {
      ...aave,
      collateralAsset: { ...aave.collateralAsset, apy: 0.076 },
      economics: { ...aave.economics, supplyApy: 0.0794 },
    }
    writeMultiplySessionState(DEMO_WALLET_ID, state)

    renderWithProviders(
      <AvanaSessionsProvider>
        <MultiplyActionPageClient kind="multiply" initialMarketId="aave-gho" initialMultiplier="1.5" />
      </AvanaSessionsProvider>,
    )

    const input = await screen.findByLabelText("Collateral amount")
    fireEvent.change(input, { target: { value: "5" } })

    // Rates moved to Market Rates on the detail page — action no longer shows this card.
    await waitFor(() => expect(screen.getByText("Net APY")).toBeInTheDocument())
    expect(screen.queryByText("Collateral APY")).not.toBeInTheDocument()
    expect(screen.queryByText("Borrow APY")).not.toBeInTheDocument()
    expect(screen.queryByText(/AAVE · 7\.94%/)).not.toBeInTheDocument()
    expect(screen.queryByText(/AAVE · 7\.60%/)).not.toBeInTheDocument()
  })

  it("falls back to a usable market instead of dead-ending on an unknown id", async () => {
    renderWithProviders(
      <AvanaSessionsProvider>
        <MultiplyActionPageClient kind="multiply" initialMarketId="not-a-market" />
      </AvanaSessionsProvider>,
    )

    // No "Market unavailable" dead-end — the action renders against a catalog
    // market and offers the picker so the user can switch.
    await waitFor(() => {
      expect(screen.getByTestId("action-amount-card")).toBeInTheDocument()
    })
    expect(screen.queryByTestId("action-not-found")).not.toBeInTheDocument()
  })
})
