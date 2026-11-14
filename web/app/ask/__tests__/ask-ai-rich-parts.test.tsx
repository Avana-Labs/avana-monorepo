import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

// Rich parts now come from the separate `messageParts` query, not embedded in
// the streamed messages. partsMock feeds that query (and harmlessly also the
// quota query, which these tests don't assert on).
const partsMock = vi.fn<() => Array<{ messageId: string; parts: unknown }>>(() => [])
vi.mock("convex/react", () => ({
  useAction: () => async () => ({ text: "Done" }),
  useQuery: () => partsMock(),
  // An active thread so the rich-parts subscriber mounts (its query is gated on a
  // resolved thread, matching production).
  usePaginatedQuery: () => ({
    results: [{ threadId: "thread-test", title: "T", status: "active", updatedAt: 1 }],
    status: "Exhausted",
    loadMore: vi.fn(),
  }),
  useMutation: () => async () => ({ threadId: "thread-test", title: "New Chat" }),
}))

const messagesMock = vi.fn()
vi.mock("@convex-dev/agent/react", () => ({
  useUIMessages: () => messagesMock(),
}))

import { AskAIPageClient } from "../ask-ai-page-client"

afterEach(() => {
  cleanup()
  messagesMock.mockReset()
  partsMock.mockReset()
  partsMock.mockReturnValue([])
})

describe("AskAIPageClient rich parts", () => {
  it("renders a financial result card and retrieval chunks from persisted richParts", () => {
    messagesMock.mockReturnValue({
      status: "Exhausted",
      loadMore: vi.fn(),
      results: [
        { id: "u1", role: "user", text: "How much can I borrow?", _creationTime: 1, status: "success" },
        {
          id: "a1",
          role: "assistant",
          text: "Here is your borrow capacity.",
          _creationTime: 2,
          status: "success",
        },
      ],
    })
    partsMock.mockReturnValue([
      {
        messageId: "a1",
        parts: {
          retrievalChunks: [
            { title: "Borrow docs", locator: "§2.1", text: "Collateral factors explained.", score: 0.91 },
          ],
          financialResults: [
            {
              kind: "borrow_capacity",
              dataProvenance: "sandbox",
              payload: {
                kind: "borrow_capacity",
                title: "Borrow capacity",
                freshness: "fresh",
                metrics: [{ label: "Available", value: "$1,200" }],
              },
            },
          ],
        },
      },
    ])

    render(<AskAIPageClient />)

    expect(screen.getByRole("region", { name: "Borrow capacity" })).toBeInTheDocument()
    expect(screen.getByText("$1,200")).toBeInTheDocument()
    expect(screen.getByText("Borrow docs")).toBeInTheDocument()
    // MarkdownText renders the answer as one node, so match the sentence.
    expect(screen.getByText(/Here is your borrow capacity/)).toBeInTheDocument()

    const timestamps = Array.from(document.querySelectorAll("time"))
    expect(timestamps).toHaveLength(2)
    for (const timestamp of timestamps) {
      expect(timestamp).toHaveClass("px-2", "py-1.5")
      expect(timestamp).not.toHaveClass("pr-2", "mt-1.5")
    }
  })

  it("reshapes a verbatim portfolio tool payload into a card", () => {
    messagesMock.mockReturnValue({
      status: "Exhausted",
      loadMore: vi.fn(),
      results: [
        {
          id: "u1",
          role: "user",
          text: "Show all my positions, Umbrella included",
          _creationTime: 1,
          status: "success",
        },
        {
          id: "a1",
          role: "assistant",
          text: "Here is your portfolio.",
          _creationTime: 2,
          status: "success",
        },
      ],
    })
    partsMock.mockReturnValue([
      {
        messageId: "a1",
        parts: {
          financialResults: [
            {
              kind: "portfolio",
              dataProvenance: "sandbox",
              payload: {
                walletRequired: false,
                dataProvenance: "sandbox",
                totals: { lendUsd: 1000, borrowUsd: 250, multiplyUsd: 0, liquidUsd: 42.5, umbrellaUsd: 500 },
                umbrella: [
                  {
                    marketSlug: "gho",
                    suppliedUsd6: "500000000",
                    cooldownAmountUsd6: "250000000",
                    cooldownEndsAt: Date.now() + 86_400_000,
                    withdrawalWindowEndsAt: Date.now() + 3 * 86_400_000,
                    lifecycleStatus: "partiallyCooling",
                  },
                ],
                asOf: 0,
              },
            },
          ],
        },
      },
    ])

    render(<AskAIPageClient />)
    expect(screen.getByRole("region", { name: "Your Avana portfolio" })).toBeInTheDocument()
    expect(screen.getByText("$1,000.00")).toBeInTheDocument()
    expect(screen.getByText("$42.50")).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Product" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Cooldown" })).toBeInTheDocument()
    expect(screen.getByText("gho")).toBeInTheDocument()
    expect(screen.getAllByText("$250.00").length).toBeGreaterThan(0)
    expect(screen.getByText(/Cooling until/)).toBeInTheDocument()
  })

  const portfolioPayload = {
    walletRequired: false,
    dataProvenance: "sandbox",
    totals: {
      lendNetValueUsd: 300152.89,
      borrowNetValueUsd: 346584.5,
      multiplyNetValueUsd: 209040.26,
      liquidNetValueUsd: 106950.48,
      netValueUsd: 962728.13,
      umbrellaUsd: 18269.51,
    },
    umbrella: [{ marketSlug: "gho", suppliedUsd6: "5000000000", cooldownAmountUsd6: "2500000000" }],
    asOf: 0,
  }
  const renderPortfolioAnswer = (question: string) => {
    messagesMock.mockReturnValue({
      status: "Exhausted",
      loadMore: vi.fn(),
      results: [
        { id: "u1", role: "user", text: question, _creationTime: 1, status: "success" },
        { id: "a1", role: "assistant", text: "Your net value is $962,728.13.", _creationTime: 2, status: "success" },
      ],
    })
    partsMock.mockReturnValue([
      {
        messageId: "a1",
        parts: { financialResults: [{ kind: "portfolio", dataProvenance: "sandbox", payload: portfolioPayload }] },
      },
    ])
    render(<AskAIPageClient />)
  }

  it("answers a plain portfolio question in text only, with no portfolio card", () => {
    renderPortfolioAnswer(
      "What is my exact net value and the four canonical component values? Show the numbers that reconcile to the total.",
    )
    expect(screen.getByText("Your net value is $962,728.13.")).toBeInTheDocument()
    expect(screen.queryByRole("region", { name: "Your Avana portfolio" })).toBeNull()
  })

  it("shows a compact product table, without Umbrella rows, when asked to see the portfolio", () => {
    renderPortfolioAnswer("Show me my portfolio")
    expect(screen.getByRole("region", { name: "Your Avana portfolio" })).toBeInTheDocument()
    expect(screen.getAllByRole("columnheader").map((header) => header.textContent)).toEqual(["Product", "Value"])
    expect(screen.getByText("$300,152.89")).toBeInTheDocument()
    expect(screen.queryByText("gho")).toBeNull()
  })

  it("renders a compact price chart without a redundant one-row market table", () => {
    messagesMock.mockReturnValue({
      status: "Exhausted",
      loadMore: vi.fn(),
      results: [
        { id: "u1", role: "user", text: "ETH price", _creationTime: 1, status: "success" },
        { id: "a1", role: "assistant", text: "ETH is $4,321.", _creationTime: 2, status: "success" },
      ],
    })
    partsMock.mockReturnValue([
      {
        messageId: "a1",
        parts: {
          financialResults: [
            {
              kind: "market",
              payload: {
                providerData: [
                  {
                    source: "defillama",
                    kind: "token_price",
                    key: "weth",
                    data: { symbol: "weth", priceUsd: 4321 },
                    freshness: "fresh",
                  },
                ],
              },
            },
          ],
          visual: { label: "WETH price", value: "$4,321.123456", delta: "+2.10%", points: [4200, 4250, 4321] },
        },
      },
    ])

    render(<AskAIPageClient />)
    expect(screen.queryByRole("columnheader", { name: "Market" })).not.toBeInTheDocument()
    expect(screen.queryByText("defillama")).not.toBeInTheDocument()
    const chart = screen.getByRole("img", { name: "WETH price: $4,321.12" })
    expect(chart).toBeInTheDocument()
    expect(chart.querySelector("path")).not.toBeInTheDocument()
    expect(screen.getByText("ETH is $4,321.")).toBeInTheDocument()
  })

  it("renders lending markets (APY + TVL) and drops the redundant lone price row", () => {
    messagesMock.mockReturnValue({
      status: "Exhausted",
      loadMore: vi.fn(),
      results: [
        { id: "u1", role: "user", text: "aave supply apy on lending markets", _creationTime: 1, status: "success" },
        { id: "a1", role: "assistant", text: "AAVE supply APY is 7.56%.", _creationTime: 2, status: "success" },
      ],
    })
    partsMock.mockReturnValue([
      {
        messageId: "a1",
        parts: {
          financialResults: [
            {
              kind: "market",
              payload: {
                // Lending data lives in `markets`; the only `providerData` hit is a
                // bare token price, which must not become the whole table.
                markets: [{ symbol: "AAVE", supplyApyPct: 7.56, tvlUsd: 101_011_986, venueLabel: "Aave" }],
                providerData: [
                  { source: "defillama", kind: "token_price", key: "aave", data: { symbol: "aave", priceUsd: 123.38 } },
                ],
              },
            },
          ],
        },
      },
    ])

    render(<AskAIPageClient />)
    expect(screen.getByRole("columnheader", { name: "Market" })).toBeInTheDocument()
    expect(screen.getByText("7.56% supply")).toBeInTheDocument()
    expect(screen.getByText("$101,011,986.00")).toBeInTheDocument()
    // The lone token-price row is dropped once a richer market row exists.
    expect(screen.queryByText("$123.38")).not.toBeInTheDocument()
  })

  it("shows only Umbrella data for an Umbrella-focused portfolio result", () => {
    messagesMock.mockReturnValue({
      status: "Exhausted",
      loadMore: vi.fn(),
      results: [
        { id: "u1", role: "user", text: "Do I have any Umbrella on cooldown?", _creationTime: 1, status: "success" },
        { id: "a1", role: "assistant", text: "Your GHO is cooling down.", _creationTime: 2, status: "success" },
      ],
    })
    partsMock.mockReturnValue([
      {
        messageId: "a1",
        parts: {
          financialResults: [
            {
              kind: "portfolio",
              payload: {
                focus: "umbrella",
                totals: { umbrellaUsd: 5_000 },
                umbrellaCooldownSummary: { coolingUsd: 2_500, readyUsd: 0 },
                umbrella: [
                  {
                    marketSlug: "gho",
                    suppliedUsd6: "5000000000",
                    cooldownAmountUsd6: "2500000000",
                    cooldownEndsAt: Date.now() + 86_400_000,
                    withdrawalWindowEndsAt: Date.now() + 3 * 86_400_000,
                    lifecycleStatus: "partiallyCooling",
                  },
                ],
              },
            },
          ],
        },
      },
    ])

    render(<AskAIPageClient />)
    expect(screen.getByRole("region", { name: "Your Umbrella positions" })).toBeInTheDocument()
    expect(screen.getAllByText("$2,500.00").length).toBeGreaterThan(0)
    expect(screen.queryByRole("columnheader", { name: "Product" })).not.toBeInTheDocument()
    expect(screen.queryByText("Liquid")).not.toBeInTheDocument()
  })

  it("does not fabricate a card when the payload is not display-ready", () => {
    messagesMock.mockReturnValue({
      status: "Exhausted",
      loadMore: vi.fn(),
      results: [
        {
          id: "a1",
          role: "assistant",
          text: "Answer.",
          _creationTime: 2,
          status: "success",
        },
      ],
    })
    partsMock.mockReturnValue([
      { messageId: "a1", parts: { financialResults: [{ kind: "portfolio", payload: { raw: 123 } }] } },
    ])

    render(<AskAIPageClient />)
    expect(screen.queryByRole("region")).not.toBeInTheDocument()
  })

  it("shows a friendly error with no feedback or retry controls for a persisted failed turn", () => {
    messagesMock.mockReturnValue({
      status: "Exhausted",
      loadMore: vi.fn(),
      results: [
        { id: "u1", role: "user", text: "Break it", _creationTime: 1, status: "success" },
        { id: "a1", role: "assistant", text: "", _creationTime: 2, status: "failed" },
      ],
    })

    render(<AskAIPageClient />)

    expect(screen.getByRole("alert")).toBeInTheDocument()
    expect(screen.getByText(/something went wrong/i)).toBeInTheDocument()
    expect(screen.queryByText(/thinking/i)).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Copy answer" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Mark answer as helpful" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Retry" })).not.toBeInTheDocument()
  })

  it("keeps thinking visible while a streaming assistant message has no renderable answer", () => {
    messagesMock.mockReturnValue({
      status: "Exhausted",
      loadMore: vi.fn(),
      results: [
        { id: "u1", role: "user", text: "How much can I borrow?", _creationTime: 1, status: "success" },
        { id: "a1", role: "assistant", text: "", _creationTime: 2, status: "streaming" },
      ],
    })

    render(<AskAIPageClient />)

    expect(screen.getByText("Thinking…")).toBeInTheDocument()
  })
})

it("reloads a persisted Aave APY chart and keeps same-symbol reserves on different chains", () => {
  messagesMock.mockReturnValue({
    status: "Exhausted",
    loadMore: vi.fn(),
    results: [{ id: "aave-1", role: "assistant", text: "These are Aave rates.", _creationTime: 2, status: "success" }],
  })
  partsMock.mockReturnValue([
    {
      messageId: "aave-1",
      parts: {
        visual: {
          kind: "aave_apy",
          label: "Aave USDC supply APY",
          value: "4.00%",
          delta: "+1.00 pp",
          points: [3, 4],
          timestamps: [1788912000000, 1788998400000],
          side: "supply",
          window: "week",
        },
        financialResults: [
          {
            kind: "market",
            payload: {
              markets: [],
              providerData: [
                {
                  source: "aave",
                  kind: "lending_market",
                  key: "v3:1:usdc",
                  data: { symbol: "USDC", market: "Aave v3 Ethereum", supplyApyPct: 4 },
                },
                {
                  source: "aave",
                  kind: "lending_market",
                  key: "v3:42161:usdc",
                  data: { symbol: "USDC", market: "Aave v3 Arbitrum", supplyApyPct: 3 },
                },
              ],
            },
          },
        ],
      },
    },
  ])
  render(<AskAIPageClient />)
  expect(screen.getByRole("img", { name: "Aave USDC supply APY: 4.00%" })).toBeInTheDocument()
  expect(screen.getByText("USDC · Aave v3 Ethereum")).toBeInTheDocument()
  expect(screen.getByText("USDC · Aave v3 Arbitrum")).toBeInTheDocument()
  expect(screen.getAllByText("Aave (cached)")).toHaveLength(2)
})
