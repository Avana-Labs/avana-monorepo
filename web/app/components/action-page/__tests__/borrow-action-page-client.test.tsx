import { act, cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import type { ReactNode } from "react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { DisplayPreferencesProvider } from "@/app/components/display-preferences"
import {
  AvanaSessionsProvider,
  useAvanaIdentity,
  useBorrowSessionContext,
} from "@/app/lib/avana-session/avana-sessions-provider"
import { BorrowActionPageClient } from "@/app/components/action-page/borrow-action-page-client"
import { repayUsdForTokenAmount } from "@/app/components/action-page/borrow-action-selection"
import { currentDebtValueUsd6, parseFixed, usd6ToNumber } from "@/app/lib/credit-engine"
import { listSpokeBorrowables } from "@/app/lib/borrow-system/registry"

const push = vi.fn()

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push, replace: vi.fn(), back: vi.fn() }),
}))

// The action client now consults wagmi (via useWrongNetwork) to gate submission. These unit
// tests render it without a WagmiProvider, so stub the two hooks the guard uses; "disconnected"
// means isWrongNetwork=false, matching the sandbox flows these tests exercise.
vi.mock("wagmi", () => ({
  useAccount: () => ({ isConnected: false, chainId: undefined }),
  useSwitchChain: () => ({ switchChainAsync: vi.fn(), isPending: false }),
}))

const renderWithProviders = (ui: ReactNode) => render(<DisplayPreferencesProvider>{ui}</DisplayPreferencesProvider>)

describe("BorrowActionPageClient", () => {
  beforeEach(() => {
    window.localStorage.clear()
    push.mockClear()
  })

  afterEach(() => {
    cleanup()
  })

  it("renders Remove as a percentage slider", async () => {
    renderWithProviders(
      <AvanaSessionsProvider>
        <BorrowActionPageClient kind="remove" initialMarketId="uni-v3-bluechip-weth-usdc" initialAmount="25" />
      </AvanaSessionsProvider>,
    )

    expect((await screen.findAllByText("Percentage to remove")).length).toBe(1)
    expect(screen.getByRole("slider", { name: "Percentage to remove" })).toHaveValue("25")
    expect(screen.getByTestId("action-leverage-pill")).toHaveTextContent("25%")
    expect(screen.queryByLabelText("Percentage to remove amount")).not.toBeInTheDocument()
    expect(screen.getByText(/Estimated removal · \$/)).toBeInTheDocument()
  })

  it("uses the same single percentage slider in the homepage workspace", async () => {
    renderWithProviders(
      <AvanaSessionsProvider>
        <BorrowActionPageClient kind="remove" embedded layout="home" />
      </AvanaSessionsProvider>,
    )

    expect(await screen.findByRole("slider", { name: "Percentage to remove" })).toBeInTheDocument()
    expect(screen.queryByLabelText("Percentage to remove amount")).not.toBeInTheDocument()
    expect(screen.getByTestId("action-leverage-pill")).toHaveTextContent("0%")
  })

  it("shows the executed USD amount after a collateral removal", async () => {
    renderWithProviders(
      <AvanaSessionsProvider>
        <BorrowActionPageClient kind="remove" initialMarketId="uni-v3-bluechip-weth-usdc" initialAmount="25" />
      </AvanaSessionsProvider>,
    )

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Review" })).toBeInTheDocument()
    })

    fireEvent.click(screen.getByRole("button", { name: "Review" }))

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Remove" })).toBeInTheDocument()
    })

    fireEvent.click(screen.getByRole("button", { name: "Remove" }))

    await waitFor(
      () => {
        expect(screen.getByText("Remove successful")).toBeInTheDocument()
      },
      { timeout: 8000 },
    )

    expect(screen.getByText("$1,050.00 processed.")).toBeInTheDocument()
  })

  it("starts Remove on the wallet collateral selector", async () => {
    renderWithProviders(
      <AvanaSessionsProvider>
        <BorrowActionPageClient kind="remove" />
      </AvanaSessionsProvider>,
    )

    expect(await screen.findByText("Choose collateral to remove.")).toBeInTheDocument()
    expect(screen.getByPlaceholderText("Search pools")).toBeInTheDocument()
    expect(screen.getAllByText("WETH / USDC").length).toBeGreaterThan(0)
    // Venue label is now the concise spoke label (e.g. "Uniswap v2 LPs"), suffixed with the
    // fee tier by formatBorrowMarketContext — match the DEX + fee without pinning the version.
    expect(screen.getAllByText(/Uniswap.*·\s*0\.30%/).length).toBeGreaterThan(0)
    expect(screen.queryByText("Choose the asset to borrow.")).not.toBeInTheDocument()
    expect(screen.queryByPlaceholderText("Find an asset")).not.toBeInTheDocument()
  })

  it("submits a repay as token amount × debt price, not the raw token count", async () => {
    const marketId = "uni-v3-bluechip-weth-usdc"
    const live: { session?: ReturnType<typeof useBorrowSessionContext>; walletId?: string } = {}
    function CaptureSession() {
      live.session = useBorrowSessionContext()
      live.walletId = useAvanaIdentity().walletId
      return null
    }
    const { rerender } = renderWithProviders(
      <AvanaSessionsProvider>
        <CaptureSession />
      </AvanaSessionsProvider>,
    )
    await waitFor(() => expect(live.session).toBeDefined())

    // Open a 0.5 WETH debt against the seeded collateral so the repay asset is priced far above $1.
    const weth = live.session!.getBorrowableAssetsForMarket(marketId).find((asset) => asset.symbol === "WETH")
    expect(weth).toBeDefined()
    const wethPriceUsd = usd6ToNumber(live.session!.state.assets[weth!.id]!.snapshot.priceUsd6)
    expect(wethPriceUsd).toBeGreaterThan(100)
    await act(async () => {
      await live.session!.executeTransaction(
        live.session!.createIntent({
          type: "borrow",
          walletId: live.walletId!,
          marketId,
          assetId: weth!.id,
          amountUsd6: parseFixed((0.5 * wethPriceUsd).toFixed(6), 6),
        }),
      )
    })
    const debt = live.session!.state.accounts[live.walletId!]!.debtPositions.find(
      (position) => position.assetId === weth!.id,
    )
    expect(debt).toBeDefined()

    rerender(
      <DisplayPreferencesProvider>
        <AvanaSessionsProvider>
          <CaptureSession />
          <BorrowActionPageClient
            kind="repay"
            initialMarketId={marketId}
            initialDebtId={debt!.id}
            initialAmount="0.25"
          />
        </AvanaSessionsProvider>
      </DisplayPreferencesProvider>,
    )

    await waitFor(() => expect(screen.getByRole("button", { name: "Review" })).toBeInTheDocument())
    fireEvent.click(screen.getByRole("button", { name: "Review" }))
    await waitFor(() => expect(screen.getByRole("button", { name: "Repay" })).toBeInTheDocument())
    fireEvent.click(screen.getByRole("button", { name: "Repay" }))
    await waitFor(() => expect(screen.getByText("Repay successful")).toBeInTheDocument(), { timeout: 8000 })

    // Repaying 0.25 of a 0.5 WETH debt leaves about half. Submitting the raw token count as USD
    // repaid $0.25 and left almost the whole debt.
    const after = live.session!.state.accounts[live.walletId!]!.debtPositions.find(
      (position) => position.id === debt!.id,
    )
    const remainingUsd = after ? usd6ToNumber(currentDebtValueUsd6(after)) : 0
    expect(remainingUsd).toBeGreaterThan(wethPriceUsd * 0.2)
    expect(remainingUsd).toBeLessThan(wethPriceUsd * 0.3)
  })

  it("converts a repay token amount with the debt asset's price and refuses an unpriced asset", () => {
    const state = {
      assets: {
        weth: { snapshot: { priceUsd6: parseFixed("3000", 6) } },
        dead: { snapshot: { priceUsd6: 0n } },
      },
    } as unknown as Parameters<typeof repayUsdForTokenAmount>[0]
    expect(repayUsdForTokenAmount(state, "weth", 0.5)).toEqual({ priceUsd: 3000, amountUsd: 1500 })
    expect(repayUsdForTokenAmount(state, "dead", 0.5)).toBeNull()
    expect(repayUsdForTokenAmount(state, "missing", 0.5)).toBeNull()
  })

  it("does not auto-select a debt from a market-only Repay URL", async () => {
    renderWithProviders(
      <AvanaSessionsProvider>
        <BorrowActionPageClient kind="repay" initialMarketId="uni-v3-bluechip-weth-usdc" />
      </AvanaSessionsProvider>,
    )

    expect(await screen.findByText("Choose the debt to repay.")).toBeInTheDocument()
    expect(screen.getByPlaceholderText("Find an asset")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Review" })).not.toBeInTheDocument()
  })

  it("keeps a token picker selection after closing the dialog", async () => {
    renderWithProviders(
      <AvanaSessionsProvider>
        <BorrowActionPageClient kind="borrow" initialMarketId="uni-v3-bluechip-weth-usdc" initialAssetId="usdc" />
      </AvanaSessionsProvider>,
    )

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Change asset, current USDC" })).toBeInTheDocument()
    })

    fireEvent.click(screen.getByRole("button", { name: "Change asset, current USDC" }))

    const dialog = await screen.findByRole("dialog", { name: "Choose asset to borrow" })
    expect(within(dialog).getByRole("button", { name: /Tether USD USDT/ })).toBeInTheDocument()

    fireEvent.click(within(dialog).getByRole("button", { name: /Tether USD USDT/ }))

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Change asset, current USDT" })).toBeInTheDocument()
    })
  })

  it("routes an unknown borrow market to the picker instead of dead-ending", async () => {
    renderWithProviders(
      <AvanaSessionsProvider>
        <BorrowActionPageClient kind="borrow" initialMarketId="not-a-market" />
      </AvanaSessionsProvider>,
    )

    // No "Market unavailable" dead-end — the user lands on the market/asset picker.
    await waitFor(() => {
      expect(screen.getByTestId("action-select-stage")).toBeInTheDocument()
    })
    expect(screen.queryByTestId("action-not-found")).not.toBeInTheDocument()
  })

  it("boots the home borrow workspace at a true zero state (no pool, no value, no health factor)", async () => {
    renderWithProviders(
      <AvanaSessionsProvider walletId="home-demo-wallet">
        <BorrowActionPageClient kind="borrow" embedded layout="home" closeHref="/" />
      </AvanaSessionsProvider>,
    )

    // The collateral context renders the unified card in its empty state — value "0"
    // and "$0.00", not a pre-selected pool (same card shown once collateral exists).
    await waitFor(() => {
      expect(screen.getAllByText("0").length).toBeGreaterThan(0)
    })
    expect(screen.getAllByText("$0.00").length).toBeGreaterThan(0)

    // Nothing should auto-select a pledged pool or surface a health factor before
    // the user acts. Give effects a tick to (not) run, then assert the zero state held.
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Enter an amount" })).toBeInTheDocument()
    })
    expect(screen.queryByText("WETH / USDC")).not.toBeInTheDocument()
    expect(screen.queryByText(/\$4,2\d\d/)).not.toBeInTheDocument()
    expect(screen.queryByText(/health factor/i)).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Review" })).not.toBeInTheDocument()
  })

  it("scopes asset-detail collateral picker to the spoke and navigates on switch", async () => {
    const gho = listSpokeBorrowables().find((asset) => asset.id === "bal-stable:gho")
    expect(gho).toBeTruthy()
    const initialMarketId = gho!.marketIds[0]
    expect(initialMarketId).toBeTruthy()
    expect(gho!.marketIds.length).toBeGreaterThan(1)

    renderWithProviders(
      <AvanaSessionsProvider>
        <BorrowActionPageClient
          kind="borrow"
          embedded
          sidebar
          closeHref="/borrow/assets/bal-stable%3Agho"
          initialMarketId={initialMarketId}
          initialAssetId="bal-stable:gho"
        />
      </AvanaSessionsProvider>,
    )

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Change asset, current GHO" })).toBeInTheDocument()
    })

    await waitFor(() => {
      expect(screen.getByTestId("action-context-selector-card")).toBeInTheDocument()
    })

    fireEvent.click(screen.getByTestId("action-context-selector-card"))

    const dialog = await screen.findByRole("dialog", { name: /Choose collateral/i })
    const poolButtons = within(dialog)
      .getAllByRole("button")
      .filter((button) => /Balancer/i.test(button.textContent ?? ""))
    expect(poolButtons.length).toBeGreaterThan(1)
    expect(poolButtons.every((button) => !/Uniswap/i.test(button.textContent ?? ""))).toBe(true)

    // Navigate the whole details page to another Balancer Stable collateral.
    fireEvent.click(poolButtons[1]!)

    await waitFor(() => {
      expect(push).toHaveBeenCalled()
    })
    const href = String(push.mock.calls.at(-1)?.[0] ?? "")
    expect(href).toMatch(/^\/borrow\/markets\/bal-stable/)
    expect(href).not.toBe(`/borrow/markets/${initialMarketId}`)
  })

  it("keeps GHO selected on asset detail even when the wallet's first pledged pool is another spoke", async () => {
    const gho = listSpokeBorrowables().find((asset) => asset.id === "bal-stable:gho")
    expect(gho).toBeTruthy()
    const initialMarketId = gho!.marketIds.find((id) => id.includes("usdc-dai-usdt")) ?? gho!.marketIds[0]
    expect(initialMarketId).toBeTruthy()

    renderWithProviders(
      <AvanaSessionsProvider walletId="demo-wallet">
        <BorrowActionPageClient
          kind="borrow"
          embedded
          sidebar
          closeHref="/borrow/assets/bal-stable%3Agho"
          initialMarketId={initialMarketId}
          initialAssetId="bal-stable:gho"
        />
      </AvanaSessionsProvider>,
    )

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Change asset, current GHO" })).toBeInTheDocument()
    })
    expect(screen.queryByRole("button", { name: /Change asset, current USDC/i })).not.toBeInTheDocument()
  })
})
