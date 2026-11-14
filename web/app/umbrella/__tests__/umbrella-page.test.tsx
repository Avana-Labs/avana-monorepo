import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { DisplayPreferencesProvider } from "@/app/components/display-preferences"
import { AvanaSessionsProvider } from "@/app/lib/avana-session/avana-sessions-provider"
import { pendingUmbrellaPersistAction } from "@/app/lib/umbrella-system/use-umbrella-session"
import UmbrellaPage from "@/app/umbrella/page"

function renderUmbrellaPage() {
  return render(
    <DisplayPreferencesProvider>
      <AvanaSessionsProvider walletId="umbrella-test-wallet" persistLocalState={false}>
        <UmbrellaPage />
      </AvanaSessionsProvider>
    </DisplayPreferencesProvider>,
  )
}

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

describe("Umbrella page", () => {
  it("renders each seeded market with its APY breakdown", async () => {
    renderUmbrellaPage()

    expect(screen.getByText("Total position value")).toBeInTheDocument()
    // The "Includes active stake and cooldown" explainer now lives under an (i) tooltip
    // instead of a visible sub-label.
    expect(screen.getByLabelText("More information about Total position value")).toBeInTheDocument()
    // Canonical compact USD is one decimal ($55.0M), shared with the rest of the app
    // (previously the Umbrella-only formatter emitted two decimals, "$55.00M"). The
    // hero market sub-label was removed, so this now anchors on the Total coverage tile.
    expect(screen.getAllByText("$55.0M").length).toBeGreaterThan(0)

    // Asset headings in the positions table
    expect(screen.getAllByText("Stake GHO").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Stake USDC").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Stake USDT").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Stake WETH").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Stable Hub Deficits").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Correlated Hub Deficits").length).toBeGreaterThan(0)

    const positions = within(screen.getByRole("region", { name: "Umbrella positions" }))
    expect(positions.getAllByText("Covered reserve").length).toBeGreaterThan(0)
    for (const label of ["Covered reserve", "Deposited", "Cooling", "Rewards"]) {
      expect(positions.getByLabelText(`More information about ${label}`)).toBeInTheDocument()
    }

    expect(positions.getByRole("columnheader", { name: "Cooling" })).toBeInTheDocument()
    expect(positions.queryByRole("columnheader", { name: "APY" })).not.toBeInTheDocument()
    const positionRows = positions.getAllByRole("row").slice(1)
    expect(positionRows.length).toBeGreaterThan(0)
    for (const row of positionRows) {
      const cells = within(row).getAllByRole("cell")
      expect(cells).toHaveLength(5)
      expect(cells[1]).not.toHaveTextContent(/cooling/i)
      expect(cells[2]).toHaveTextContent(/\$/)
    }
    // Rewards shows the reward APY over the live accrued rewards counter.
    expect(positions.getAllByText("6.4%").length).toBeGreaterThan(0)
    expect(positions.getAllByText("3.12%").length).toBeGreaterThan(0)
    expect(positions.getAllByText("2.85%").length).toBeGreaterThan(0)
    expect(positions.getAllByText("2.4%").length).toBeGreaterThan(0)

    // Surface details is independent from the action market and starts on the first icon.
    expect(screen.getByRole("heading", { name: "GHO Stable Hub Reserve" })).toBeInTheDocument()
    expect(screen.getByLabelText("More information about GHO Stable Hub Reserve")).toBeInTheDocument()
    const surfaceTabs = screen.getByRole("tablist", { name: "Umbrella surface details" })
    expect(within(surfaceTabs).getByRole("tab", { name: "View GHO surface details" })).toHaveAttribute(
      "aria-selected",
      "true",
    )
    fireEvent.click(within(surfaceTabs).getByRole("tab", { name: "View USDC surface details" }))
    expect(screen.getByRole("heading", { name: "USDC Stable Hub Reserve" })).toBeInTheDocument()
    fireEvent.click(screen.getByLabelText("More information about USDC Stable Hub Reserve"))
    expect(screen.getByRole("tooltip")).toHaveTextContent(
      "This covers deficits impacting Stable LP Hub USDC suppliers, including deficits originated by All Spokes borrowing the USDC reserve.",
    )
    expect(screen.queryByText("Risk Parameters")).not.toBeInTheDocument()
    expect(screen.queryByText("Coverage mode")).not.toBeInTheDocument()
    expect(screen.getByText("Active staker capital")).toBeInTheDocument()
    await waitFor(() => {
      expect(screen.getAllByText("$12.0M").length).toBeGreaterThanOrEqual(2)
      expect(screen.getByText("Coverage ratio")).toBeInTheDocument()
      expect(screen.getAllByText("120%").length).toBeGreaterThanOrEqual(2)
    })
    // The action page keeps secondary details hidden until an amount is entered;
    // the large main-page Surface details section does not include APY breakdown.
    expect(screen.queryByText("APY breakdown")).not.toBeInTheDocument()
    expect(screen.getByLabelText("More information about Local deductible")).toBeInTheDocument()
    expect(screen.getByLabelText("More information about DAO first-loss offset")).toBeInTheDocument()
    expect(screen.getByLabelText("More information about Hub tail target")).toBeInTheDocument()
    expect(screen.getByLabelText("More information about Cooldown queue")).toBeInTheDocument()

    expect(screen.getByText("Hub + reserve coverage")).toBeInTheDocument()
    expect(screen.getByText("First-loss protection")).toBeInTheDocument()
    expect(screen.getByText("Independent underwriting")).toBeInTheDocument()
    expect(screen.getByText(/The Deficit Offset absorbs the first layer of loss/)).toBeInTheDocument()
    expect(screen.getByText(/\$55\.0M staked\s+\$47\.8M target/)).toBeInTheDocument()
    expect(screen.getByText(/9\.36% of coverage cooling\s+\$136\.9K deficits absorbed/)).toBeInTheDocument()
  })

  it("shows the 20-day cooldown and 2-day unstake window", () => {
    renderUmbrellaPage()

    expect(screen.getByText("Cooldown: 20 days · Unstake window: 2 days")).toBeInTheDocument()
  })

  it("hides Umbrella page values when the Your Umbrella eye is toggled", () => {
    renderUmbrellaPage()

    fireEvent.click(screen.getByRole("button", { name: "Hide Numbers" }))

    expect(screen.getByRole("button", { name: "Show Numbers" })).toBeInTheDocument()
    expect(screen.queryByText("$55.0M")).not.toBeInTheDocument()
    expect(screen.queryByText("$12.0M")).not.toBeInTheDocument()
    expect(screen.queryByText("6.4%")).not.toBeInTheDocument()
    expect(screen.getAllByText("••••").length).toBeGreaterThan(10)
  })

  it("reveals secondary action details after an amount is entered", () => {
    renderUmbrellaPage()

    expect(screen.queryByText("APY breakdown")).not.toBeInTheDocument()
    expect(screen.queryByText("Slashable stake")).not.toBeInTheDocument()
    expect(screen.queryByText("Avana Platform Fee")).not.toBeInTheDocument()

    fireEvent.change(screen.getByRole("textbox", { name: /amount/i }), { target: { value: "1000" } })

    expect(screen.getByText("APY breakdown")).toBeInTheDocument()
    expect(screen.getByText("Est. annual rewards")).toBeInTheDocument()
    expect(screen.getByText("Based on amount entered")).toBeInTheDocument()
    expect(screen.getByText("Slashable stake")).toBeInTheDocument()
    expect(screen.getByText("Avana Platform Fee")).toBeInTheDocument()
  })

  it("places cooldown immediately after positions and before market-level risk", () => {
    renderUmbrellaPage()

    const headings = screen.getAllByRole("heading").map((heading) => heading.textContent)
    const positionsIndex = headings.indexOf("Umbrella positions")
    const cooldownIndex = headings.indexOf("Umbrella Cooldown")
    const marketRiskIndex = headings.indexOf("Umbrella Overview")

    expect(cooldownIndex).toBe(positionsIndex + 1)
    expect(marketRiskIndex).toBe(cooldownIndex + 1)
  })

  it("uses independent surface tabs for the large Surface details section", () => {
    renderUmbrellaPage()

    const surfaceTabs = screen.getByRole("tablist", { name: "Umbrella surface details" })
    expect(within(surfaceTabs).getAllByRole("tab")).toHaveLength(4)
    expect(within(surfaceTabs).getByRole("tab", { name: "View GHO surface details" })).toHaveAttribute(
      "aria-selected",
      "true",
    )

    fireEvent.click(within(surfaceTabs).getByRole("tab", { name: "View WETH surface details" }))

    expect(screen.getByRole("heading", { name: "WETH Correlated Hub Reserve" })).toBeInTheDocument()
    expect(screen.getByLabelText("More information about WETH Correlated Hub Reserve")).toBeInTheDocument()
    expect(within(surfaceTabs).getByRole("tab", { name: "View WETH surface details" })).toHaveAttribute(
      "aria-selected",
      "true",
    )
  })

  it("never renders an Unstake CTA in the positions table (Claim is the only row action)", () => {
    renderUmbrellaPage()

    // Scope to the positions table region — unstaking still lives in the sidebar action rail.
    const positions = within(screen.getByRole("region", { name: "Umbrella positions" }))
    const links = positions.getAllByRole("link")
    // No Unstake row action, even for positions whose cooldown is ready (e.g. seeded USDT).
    expect(links.some((link) => link.getAttribute("href")?.startsWith("/actions/umbrella/unstake"))).toBe(false)
    // Positions with pending rewards still expose a Claim row action.
    expect(links.some((link) => link.getAttribute("href")?.startsWith("/actions/umbrella/claim"))).toBe(true)
  })

  it("exposes the four action tabs in the sidebar rail", () => {
    renderUmbrellaPage()

    const tablist = screen.getByRole("tablist", { name: "Umbrella actions" })
    for (const label of ["Stake", "Claim", "Cooldown", "Unstake"]) {
      expect(within(tablist).getByRole("tab", { name: label })).toBeInTheDocument()
    }
  })

  it("shows a loading skeleton (never demo stakes) while the Convex umbrella snapshot is pending", () => {
    render(
      <DisplayPreferencesProvider>
        <AvanaSessionsProvider
          walletId="umbrella-test-wallet"
          persistLocalState={false}
          persistUmbrellaState={false}
          sessionSource="convex"
          authoritativeWalletPending
          persistUmbrellaAction={pendingUmbrellaPersistAction}
        >
          <UmbrellaPage />
        </AvanaSessionsProvider>
      </DisplayPreferencesProvider>,
    )

    // Single hydration gate: while the umbrella query is pending we render the
    // layout-matched skeleton — never the seeded demo stakes, never a flash of $0
    // tiles or the "no positions" empty state (those are real, hydrated content).
    expect(screen.getByRole("status", { name: "Loading" })).toBeInTheDocument()
    expect(screen.queryByText("$38,544")).not.toBeInTheDocument()
    expect(screen.queryByText("Stake GHO")).not.toBeInTheDocument()
    expect(screen.queryByText("You have no Umbrella positions yet.")).not.toBeInTheDocument()
  })
})
