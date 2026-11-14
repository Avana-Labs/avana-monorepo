import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { buildPositionContext } from "@/app/lib/ask-ai/position-context"
import { buildRiskRun } from "@/app/lib/ask-ai/mode-run"

const partsMock = vi.fn<() => Array<{ messageId: string; parts: unknown }>>(() => [])
vi.mock("convex/react", () => ({
  useAction: () => async () => ({ text: "Done" }),
  useQuery: () => partsMock(),
  usePaginatedQuery: () => ({
    results: [{ threadId: "thread-test", title: "T", status: "active", updatedAt: 1 }],
    status: "Exhausted",
    loadMore: vi.fn(),
  }),
  useMutation: () => async () => ({ threadId: "thread-test", title: "New Chat" }),
}))

const messagesMock = vi.fn()
vi.mock("@convex-dev/agent/react", () => ({ useUIMessages: () => messagesMock() }))

import { AskAIPageClient } from "../ask-ai-page-client"

const run = buildRiskRun(
  buildPositionContext(
    {
      positionId: "pos_1",
      product: "borrow",
      collateralValueUsd: 10_000,
      debtValueUsd: 5_000, // HF 1.30 → defensive actions present
      maxLtvPct: 55,
      liquidationThresholdPct: 65,
      borrowApyPct: 5,
      lpFeeApr7dPct: 18.25,
      lastUpdatedAt: 1,
    },
    2,
  ),
  { queryText: "am I safe?", provenance: "sandbox" },
)

function seedModeRunMessage() {
  messagesMock.mockReturnValue({
    status: "Exhausted",
    loadMore: vi.fn(),
    results: [
      { id: "u1", role: "user", text: "Am I safe?", _creationTime: 1, status: "success" },
      { id: "a1", role: "assistant", text: "Here is your risk.", _creationTime: 2, status: "success" },
    ],
  })
  partsMock.mockReturnValue([{ messageId: "a1", parts: { modeRun: run } }])
}

beforeEach(() => {
  delete process.env.NEXT_PUBLIC_ASK_AI_MODE_RUNS
})
afterEach(() => {
  cleanup()
  messagesMock.mockReset()
  partsMock.mockReset()
  partsMock.mockReturnValue([])
  delete process.env.NEXT_PUBLIC_ASK_AI_MODE_RUNS
})

describe("Ask AI mode-run wiring", () => {
  it("renders the mode-run cards in the thread when the flag is on", () => {
    process.env.NEXT_PUBLIC_ASK_AI_MODE_RUNS = "1"
    seedModeRunMessage()
    render(<AskAIPageClient />)
    expect(screen.getByText("Position risk")).toBeInTheDocument()
    expect(screen.getByText("Suggested actions")).toBeInTheDocument()
    expect(screen.getByText(/Here is your risk/)).toBeInTheDocument()
  })

  it("does not render the mode-run cards when the flag is off (default)", () => {
    seedModeRunMessage()
    render(<AskAIPageClient />)
    expect(screen.queryByText("Position risk")).not.toBeInTheDocument()
    expect(screen.queryByText("Suggested actions")).not.toBeInTheDocument()
    // The normal assistant answer still renders — the chat is unchanged.
    expect(screen.getByText(/Here is your risk/)).toBeInTheDocument()
  })

  it.each(["What is the current GHO supply APY?", "Show me the current GHO supply APY"])(
    "filters a stale persisted mode-run from %s",
    (prompt) => {
      process.env.NEXT_PUBLIC_ASK_AI_MODE_RUNS = "1"
      messagesMock.mockReturnValue({
        status: "Exhausted",
        loadMore: vi.fn(),
        results: [
          { id: "u1", role: "user", text: prompt, _creationTime: 1, status: "success" },
          { id: "a1", role: "assistant", text: "Supply APY: 0.0292", _creationTime: 2, status: "success" },
        ],
      })
      partsMock.mockReturnValue([{ messageId: "a1", parts: { modeRun: { ...run, queryText: prompt } } }])

      render(<AskAIPageClient />)
      expect(screen.queryByText("Position risk")).not.toBeInTheDocument()
      expect(screen.getByText(/Supply APY/)).toBeInTheDocument()
    },
  )
})
