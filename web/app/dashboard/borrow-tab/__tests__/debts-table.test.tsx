import { render, cleanup } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { CurrentLtvCard, DebtsPanel } from "../debts-table"
import type { DebtRowContext } from "@/app/lib/data/borrow-position-types"

// The debt row derives its token quantity from the live price (USD ÷ price), so pin
// deterministic prices: a $1 stablecoin (USDT) and a volatile asset (WETH ≈ $2,450).
vi.mock("@/app/lib/prices/token-prices-context", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/app/lib/prices/token-prices-context")>()
  const prices: Record<string, number> = { USDT: 1, WETH: 2450 }
  return { ...actual, useCanonicalPriceFor: () => (symbol: string) => prices[symbol.toUpperCase()] }
})

const pool = {
  id: "curve-usdc-usdt",
  name: "USDC / USDT",
  venue: "Curve",
  category: "0.01%",
  collateralUsd: 10_000,
  maxLtv: 90,
  borrowPowerUsd: 9_000,
  liquidationUsd: 9_500,
  pairApr: 2.1,
  visuals: [
    { symbol: "USDC", shortLabel: "U", bgClassName: "bg-sky-100", textClassName: "text-sky-700" },
    { symbol: "USDT", shortLabel: "T", bgClassName: "bg-emerald-100", textClassName: "text-emerald-700" },
  ] as [
    { symbol: string; shortLabel: string; bgClassName: string; textClassName: string },
    { symbol: string; shortLabel: string; bgClassName: string; textClassName: string },
  ],
}

const usdtDebt: DebtRowContext = {
  id: "debt-usdc-usdt",
  pool,
  debtAssetSymbol: "USDT",
  borrowedUsd: 6_200,
  liquidationThresholdUsd: 9_500,
  healthFactor: 1.8,
  borrowApr: 5.5,
  accruedInterestUsd: 33.6,
  dailyInterestUsd: 0.94,
}

// ~1.01 WETH at ~$2,450 = $2,471, stored as a USD amount (currentDebtValueUsd6). The
// row must show the token quantity (~1.01 WETH) over the USD ($2,471), never the USD
// amount rendered as a token count ("2471 WETH") nor borrowedUsd × price ($6M).
const wethDebt: DebtRowContext = {
  id: "debt-uni-v2-weth",
  pool,
  debtAssetSymbol: "WETH",
  borrowedUsd: 2_471,
  liquidationThresholdUsd: 9_500,
  healthFactor: 2.4,
  borrowApr: 3.2,
  accruedInterestUsd: 1.2,
  dailyInterestUsd: 0.21,
}

describe("DebtsPanel", () => {
  afterEach(() => {
    cleanup()
  })

  it("shows a lend-style empty state with heading and count", () => {
    const { container } = render(
      <DebtsPanel
        rows={[]}
        totals={{
          totalBorrowed: 0,
          totalCollateral: 0,
          averageHf: null,
          accruedInterest: 0,
          dailyInterest: 0,
        }}
        onRepay={vi.fn()}
        showSummary={false}
      />,
    )

    expect(container.textContent).toMatch(/My Debts/)
    expect(container.textContent).toMatch(/0 loans/)
    expect(container.textContent).toMatch(/No active loans\. Borrow against your collateral to get started\./)
    expect(container.textContent).not.toMatch(/Nothing borrowed yet/)
    expect(container.textContent).not.toMatch(/To borrow you need to supply any LPs/)
  })

  it("renders the position's actual debt asset symbol, not a hardcoded USDC", () => {
    const { container } = render(
      <DebtsPanel
        rows={[usdtDebt]}
        totals={{
          totalBorrowed: 6_200,
          totalCollateral: 10_000,
          averageHf: 1.8,
          accruedInterest: 33.6,
          dailyInterest: 0.94,
        }}
        onRepay={vi.fn()}
        showSummary={false}
        showHeading={false}
      />,
    )

    // The debt-amount primary line uses the real debt asset (USDT), as a token quantity.
    expect(container.textContent).toMatch(/6\.20K\s+USDT/)
    // No hardcoded USDC quantity is emitted for a USDT debt.
    expect(container.textContent).not.toMatch(/6\.20K\s+USDC/)
  })

  it("surfaces borrow rate over live-accruing interest owed as a desktop column", () => {
    const { container } = render(
      <DebtsPanel
        rows={[usdtDebt]}
        totals={{
          totalBorrowed: 6_200,
          totalCollateral: 10_000,
          averageHf: 1.8,
          accruedInterest: 33.6,
          dailyInterest: 0.94,
        }}
        onRepay={vi.fn()}
        showSummary={false}
        showHeading={false}
      />,
    )

    // The borrow rate is a simple-interest APR, so the column reads APR (not APY): big borrow rate on
    // top, the interest owed accruing (from the recorded base) beneath it.
    expect(container.textContent).toMatch(/APR/)
    expect(container.textContent).not.toMatch(/APY/)
    expect(container.textContent).toMatch(/5\.50%/)
    expect(container.textContent).toMatch(/33\.60/)
  })

  it("shows the debt as a token amount over its live USD value, with Borrow + Repay CTAs", () => {
    const { container, getAllByRole } = render(
      <DebtsPanel
        rows={[usdtDebt]}
        totals={{
          totalBorrowed: 6_200,
          totalCollateral: 10_000,
          averageHf: 1.8,
          accruedInterest: 33.6,
          dailyInterest: 0.94,
        }}
        onRepay={vi.fn()}
        showSummary={false}
        showHeading={false}
      />,
    )

    // Borrowed reads token-amount-over-USD (like Lend "Deposited"). Mobile offers
    // Borrow + Repay as the dual CTA pair (same chrome as Lend Add / Withdraw).
    expect(container.textContent).toMatch(/6\.20K\s+USDT/)
    expect(getAllByRole("button", { name: /Repay/ }).length).toBeGreaterThan(0)
  })

  it("renders a volatile debt as a token quantity over USD, not the USD amount as a token count", () => {
    const { container } = render(
      <DebtsPanel
        rows={[wethDebt]}
        totals={{
          totalBorrowed: 2_471,
          totalCollateral: 10_000,
          averageHf: 2.4,
          accruedInterest: 1.2,
          dailyInterest: 0.21,
        }}
        onRepay={vi.fn()}
        showSummary={false}
        showHeading={false}
      />,
    )

    // Primary line is the token quantity owed (~1.01 WETH), not the USD amount rendered
    // as a token count ("2471 WETH"). Secondary line is the real USD value ($2,471), not
    // borrowedUsd × price (~$6M).
    expect(container.textContent).toMatch(/1\.01\s+WETH/)
    expect(container.textContent).not.toMatch(/2471\s+WETH/)
    expect(container.textContent).toMatch(/\$2,471/)
    expect(container.textContent).not.toMatch(/\$6,0\d\d,\d\d\d/)
  })

  it("does not render a bare Opened placeholder row", () => {
    const { container } = render(
      <DebtsPanel
        rows={[usdtDebt]}
        totals={{
          totalBorrowed: 6_200,
          totalCollateral: 10_000,
          averageHf: 1.8,
          accruedInterest: 33.6,
          dailyInterest: 0.94,
        }}
        onRepay={vi.fn()}
        showSummary={false}
        showHeading={false}
      />,
    )

    expect(container.textContent).not.toMatch(/Opened/)
    expect(container.textContent).not.toMatch(/—/)
  })
})

describe("CurrentLtvCard borrowing-power status", () => {
  afterEach(() => {
    cleanup()
  })

  it("reads NONE (not RISK) when there is no collateral and no debt", () => {
    const { container } = render(<CurrentLtvCard borrowedUsd={0} collateralUsd={0} showBalance />)
    expect(container.textContent).toMatch(/NONE/)
    expect(container.textContent).not.toMatch(/RISK/)
  })

  it("reads GOOD when a healthy position has remaining borrowing power", () => {
    const { container } = render(<CurrentLtvCard borrowedUsd={2_000} collateralUsd={10_000} showBalance />)
    expect(container.textContent).toMatch(/GOOD/)
  })

  it("surfaces borrowing cost (interest per day + accrued) when provided", () => {
    const { container } = render(
      <CurrentLtvCard
        borrowedUsd={6_200}
        collateralUsd={10_000}
        showBalance
        dailyInterestUsd={0.94}
        accruedInterestUsd={33.6}
      />,
    )
    expect(container.textContent).toMatch(/Interest \/ day/)
    expect(container.textContent).toMatch(/Accrued interest/)
    expect(container.textContent).toMatch(/0\.94/)
    expect(container.textContent).toMatch(/33\.60/)
  })

  it("omits the borrowing-cost row when no interest figures are passed", () => {
    const { container } = render(<CurrentLtvCard borrowedUsd={2_000} collateralUsd={10_000} showBalance />)
    expect(container.textContent).not.toMatch(/Interest \/ day/)
    expect(container.textContent).not.toMatch(/Accrued interest/)
  })
})
