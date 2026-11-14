import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"
import { AskAIAaveChart } from "../components/ask-ai-aave-chart"
import { AskAIMarkdown } from "../components/ask-ai-markdown"
import { AskAIFinancialResultCard } from "../components/ask-ai-financial-result-card"
import { buildAaveCard } from "../components/ask-ai-aave-card"
import { aaveApyVisual, aaveEnvelope } from "@/app/lib/ask-ai/aave-mcp"
import { sanitizeAskAISources } from "@/app/lib/ask-ai/sources"

afterEach(cleanup)

describe("Aave rich results", () => {
  it("renders a real APY series through the existing chart with dates and percentage-point change", () => {
    const visual = aaveApyVisual(
      [
        { date: "2026-09-09", apyPct: "4" },
        { date: "2026-09-10", apyPct: "3.5" },
      ],
      "Aave v3 Ethereum USDC",
      "supply",
      "week",
    )!
    const { container } = render(<AskAIAaveChart visual={visual} />)
    expect(screen.getByRole("img", { name: /Aave v3 Ethereum USDC supply APY: 3.50%/ })).toBeInTheDocument()
    expect(screen.getByText("-0.50 pp")).toBeInTheDocument()
    expect(screen.getByText("Sep 9 – Sep 10 (UTC)")).toBeInTheDocument()
    expect(container.querySelector('[data-slot="chart"] polyline')).toHaveAttribute("points")
  })

  it("shows Aave on-chain figures and Avana sandbox balances separately", () => {
    const card = buildAaveCard(
      "aave_positions",
      aaveEnvelope({
        summary: { v4: { totalSuppliedUsd: "1000", totalDebtUsd: "250" } },
        avanaSandbox: { totals: { lendUsd: 500 } },
      }),
    )!
    render(<AskAIFinancialResultCard result={card} />)
    expect(screen.getByRole("region", { name: "Your Aave vs Avana" })).toBeInTheDocument()
    expect(screen.getByText("Aave on-chain v4 Debt")).toBeInTheDocument()
    expect(screen.getByText("Avana sandbox Lend")).toBeInTheDocument()
    expect(screen.queryByText("$1,500")).not.toBeInTheDocument()
  })

  it("renders governance status, quorum and votes as text with no proposal-body link", () => {
    const card = buildAaveCard(
      "aave_governance",
      aaveEnvelope({
        proposalId: "516",
        title: "[Vote](https://evil.example)",
        state: "active",
        votesFor: "320001",
        votesAgainst: "1",
        quorum: "320000",
        quorumMet: true,
      }),
    )!
    const { container } = render(<AskAIFinancialResultCard result={card} />)
    expect(screen.getByText("Quorum (AAVE)")).toBeInTheDocument()
    expect(screen.getByText("320,000")).toBeInTheDocument()
    expect(screen.getByText("Met")).toBeInTheDocument()
    expect(container.querySelector("a")).toBeNull()
  })

  it("shows token-denominated caps and eMode badges", () => {
    const card = buildAaveCard(
      "aave_reserve",
      aaveEnvelope({
        symbol: "USDC",
        maxLtvPct: "75",
        liquidationThresholdPct: "78",
        supplyCap: { value: "3000000000", usd: "2990000000" },
        eModes: [{ label: "Stablecoins" }],
      }),
    )!
    render(<AskAIFinancialResultCard result={card} />)
    expect(screen.getByText("75%")).toBeInTheDocument()
    expect(screen.getByText("Supply cap (tokens)")).toBeInTheDocument()
    expect(screen.getByText("3,000,000,000")).toBeInTheDocument()
    expect(screen.getByText("eMode: Stablecoins")).toBeInTheDocument()
  })

  it("strips claim transactions and renders only claimable reward chips", () => {
    const payload = aaveEnvelope({
      v3: {
        rewards: [
          {
            chainId: 1,
            claimable: [{ currency: { symbol: "GHO" }, amount: { amount: { value: "12.5" }, usd: "12.5" } }],
            transaction: { to: "0x1234", data: "0x5678" },
          },
        ],
      },
    })
    const card = buildAaveCard("aave_rewards", payload)!
    render(<AskAIFinancialResultCard result={card} />)
    expect(screen.getByText("12.5 GHO claimable")).toBeInTheDocument()
    expect(JSON.stringify(card)).not.toContain("0x")
  })

  it("keeps hostile streamed links, images and addresses non-actionable", () => {
    const { container } = render(
      <AskAIMarkdown
        text={
          "[Click](https://evil.example) ![Tracker](https://evil.example/x.png) <https://evil.example> [Fake](javascript:alert(1)) [Spoof](https://aave.com.evil.example) [Aave](https://aave.com/docs/mcp)"
        }
      />,
    )
    expect(container.querySelectorAll("a")).toHaveLength(1)
    expect(container.querySelector("a")).toHaveAttribute("href", "https://aave.com/docs/mcp")
    expect(container.querySelector("img")).toBeNull()
    expect(
      sanitizeAskAISources([{ title: "Bad", domain: "Aave", kind: "aave", url: "https://evil.example" }])[0],
    ).not.toHaveProperty("url")
  })
})
