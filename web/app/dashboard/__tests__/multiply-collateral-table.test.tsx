import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { PortfolioMultiplyCollateral } from "@/app/lib/data/providers/portfolio"
import { MultiplyCollateralTable } from "@/app/dashboard/multiply-collateral-table"
import type { MultiplyPositionLiveApy } from "@/app/dashboard/dashboard-tab-metrics"
import { DisplayPreferencesProvider } from "@/app/components/display-preferences"

const push = vi.fn()

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push }),
}))

const rows: PortfolioMultiplyCollateral[] = [
  {
    id: "demo-wallet:eth-usdt",
    marketId: "eth-usdt",
    label: "ETH/USDT",
    collateralToken: "ETH",
    borrowableToken: "USDT",
    multiplier: 2,
    protocol: "Avana Multiply",
    healthFactor: 1.45,
    collateralUsd: 7000,
    borrowPowerUsd: 3500,
    debtUsd: 3500,
    ltvPct: 50,
    liquidationPriceUsd: 2100,
    netApyPct: 3.2,
    status: "open",
  },
]

const ghostRows: PortfolioMultiplyCollateral[] = [
  {
    id: "demo-wallet:aave-gho",
    marketId: "aave-gho",
    label: "AAVE/GHO",
    collateralToken: "AAVE",
    borrowableToken: "GHO",
    multiplier: 1,
    protocol: "Avana Multiply",
    healthFactor: Number.POSITIVE_INFINITY,
    collateralUsd: 0,
    borrowPowerUsd: 0,
    debtUsd: 0,
    ltvPct: 0,
    liquidationPriceUsd: null,
    netApyPct: 0,
    status: "open",
  },
]

describe("MultiplyCollateralTable", () => {
  afterEach(() => {
    cleanup()
  })

  it("hides zero-exposure ghost positions and shows a clean empty state", () => {
    render(
      <DisplayPreferencesProvider>
        <MultiplyCollateralTable rows={ghostRows} />
      </DisplayPreferencesProvider>,
    )

    expect(screen.getByText("No active Multiply positions")).toBeTruthy()
    // No ghost card and no "1 positions" count for an effectively-empty position.
    expect(screen.queryByText("AAVE/GHO")).toBeNull()
    expect(screen.queryByText("1 positions")).toBeNull()
  })

  it("excludes closed positions from the active count", () => {
    render(
      <DisplayPreferencesProvider>
        <MultiplyCollateralTable rows={[...rows, { ...rows[0]!, id: "closed", status: "closed" }]} />
      </DisplayPreferencesProvider>,
    )

    // One Manage arrow for the single open row (desktop and phones share the table).
    expect(screen.getAllByRole("button", { name: "Manage" })).toHaveLength(1)
  })

  it("shows the projected liquidation price, tagged with the collateral token", () => {
    render(
      <DisplayPreferencesProvider>
        <MultiplyCollateralTable rows={rows} />
      </DisplayPreferencesProvider>,
    )

    // liquidationPriceUsd (2100) is surfaced exact (once per responsive layout:
    // desktop table + mobile card) rather than compacted to "$2.1K", and now names
    // the collateral asset whose price is being quoted: "Liq. price $2,100 (ETH)".
    expect(screen.getAllByText(/\$2,100/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/Liq\. .*\(ETH\)/).length).toBeGreaterThan(0)
    expect(screen.getByRole("columnheader", { name: /RISK/i })).toBeTruthy()
  })

  it("renders one compact My Loops table with one action per position", () => {
    render(
      <DisplayPreferencesProvider>
        <MultiplyCollateralTable rows={rows} />
      </DisplayPreferencesProvider>,
    )

    expect(screen.getByRole("heading", { name: "My Loops" })).toBeTruthy()
    // Header subtitle is now a count, mirroring the Lend/Borrow tables ("8 assets").
    expect(screen.getByText("1 loop")).toBeTruthy()
    // Columns each carry an (i) help button, so match the header label with a regex.
    expect(screen.getByRole("columnheader", { name: /LOOP/i })).toBeTruthy()
    expect(screen.getByRole("columnheader", { name: /VALUE/i })).toBeTruthy()
    expect(screen.getByRole("columnheader", { name: /APY/i })).toBeTruthy()
    expect(screen.getByRole("columnheader", { name: /RISK/i })).toBeTruthy()
    expect(screen.queryByRole("columnheader", { name: /EQUITY/i })).toBeNull()
    expect(screen.getAllByRole("button", { name: "Manage" })).toHaveLength(1)
    // Loop identity is a compact "COLLATERAL / BORROW" pair with leverage on the caption
    // line below it — no "Supply …"/"Borrow …" verbs.
    expect(screen.getAllByText("ETH / USDT")).toHaveLength(1)
    expect(screen.getAllByText(/2\.00x leverage/).length).toBeGreaterThan(0)
    // Value cell = equity primary + exposure ("Exp.") subtitle; debt is gone.
    expect(screen.getAllByText("$3.5K").length).toBeGreaterThan(0)
    expect(screen.getAllByText(/\$7\.0K/).length).toBeGreaterThan(0)
    expect(screen.queryByText(/\$3\.5K debt/)).toBeNull()
  })

  it("renders per-loop Net APY and live carry when apy terms are supplied", () => {
    const netApyByMarket = new Map<string, MultiplyPositionLiveApy>([
      ["eth-usdt", { netApyPct: 6.2, ratePerYearUsd: 217, baseUsd: 12.5, accrualSinceMs: Date.now() }],
    ])
    render(
      <DisplayPreferencesProvider>
        <MultiplyCollateralTable rows={rows} netApyByMarket={netApyByMarket} />
      </DisplayPreferencesProvider>,
    )

    // Signed net APY (desktop + mobile) and the live carry line ticking up from baseUsd.
    expect(screen.getAllByText("+6.20%").length).toBeGreaterThan(0)
    expect(screen.getAllByText(/\$12\.5/).length).toBeGreaterThan(0)
  })

  it("renders a dash when a position has no liquidation price (debt-free)", () => {
    render(
      <DisplayPreferencesProvider>
        <MultiplyCollateralTable rows={[{ ...rows[0]!, debtUsd: 0, liquidationPriceUsd: null }]} />
      </DisplayPreferencesProvider>,
    )

    expect(screen.getAllByText(/—/).length).toBeGreaterThan(0)
  })

  it("routes desktop Manage to the loop market page", () => {
    push.mockClear()
    render(
      <DisplayPreferencesProvider>
        <MultiplyCollateralTable rows={rows} />
      </DisplayPreferencesProvider>,
    )

    fireEvent.click(screen.getAllByRole("button", { name: "Manage" })[0]!)
    expect(push).toHaveBeenCalledWith("/multiply/markets/eth-usdt")
  })
})
