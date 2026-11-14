import { cleanup, render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { afterEach, describe, expect, it, vi } from "vitest"
import { AskAIPageClient } from "../ask-ai-page-client"

vi.mock("convex/react", () => ({
  useAction: () => async () => ({ text: "Done" }),
  useQuery: (_query: unknown, args: unknown) =>
    args === "skip" ? undefined : { used: 0, limit: 20, resetsAt: Date.now() + 60_000 },
  usePaginatedQuery: () => ({ results: [], status: "Exhausted", loadMore: vi.fn() }),
  useMutation: () => async () => ({ threadId: "thread-test", title: "New Chat" }),
}))

vi.mock("@convex-dev/agent/react", () => ({
  useUIMessages: () => ({ results: [], status: "Exhausted", loadMore: vi.fn() }),
}))

afterEach(cleanup)

describe("AskAIPageClient", () => {
  it("renders the public empty state and scoped suggestions", () => {
    render(<AskAIPageClient />)

    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent(
      /Good morning!|Good afternoon!|Good evening!|Welcome back!|Hey!/,
    )
    expect(screen.getByRole("button", { name: /Positions: Analyze my positions/i })).toBeInTheDocument()
    expect(screen.queryByText(/GPT-5.6 Luna/i)).not.toBeInTheDocument()
    // Attachment and voice inputs were removed from the composer.
    expect(screen.queryByRole("button", { name: "Add attachment" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /voice input/i })).not.toBeInTheDocument()
    expect(screen.getByRole("textbox", { name: "Ask Avana a question" })).toHaveAttribute("maxlength", "2000")
  })

  it("previews the suggestion prompt in the composer on hover", async () => {
    const user = userEvent.setup()
    render(<AskAIPageClient />)

    const composer = screen.getByRole("textbox", { name: "Ask Avana a question" })
    expect(composer).toHaveValue("")

    const borrow = screen.getByRole("button", { name: /Borrow: How much can I borrow/i })
    const risk = screen.getByRole("button", { name: /Risk: What is my health factor/i })

    await user.hover(borrow)
    expect(composer).toHaveValue("How much can I borrow?")

    // Crossing the gap to another chip should keep a preview (no placeholder flash).
    await user.hover(risk)
    expect(composer).toHaveValue("What is my health factor?")

    await user.unhover(risk)
    expect(composer).toHaveValue("")
  })

  it("hides and opens the thread sidebar", async () => {
    const user = userEvent.setup()
    render(<AskAIPageClient />)

    await user.click(screen.getByRole("button", { name: "Open sidebar" }))
    expect(screen.getByRole("button", { name: "Hide sidebar" })).toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: "Hide sidebar" }))
    expect(screen.getByRole("button", { name: "Open sidebar" })).toBeInTheDocument()
  })

  it("opens a local draft thread without changing sidebar state", async () => {
    const user = userEvent.setup()
    render(<AskAIPageClient />)

    await user.click(screen.getByRole("button", { name: "Open sidebar" }))
    await user.click(screen.getByRole("button", { name: "New Thread" }))
    expect(screen.getByRole("button", { name: "Hide sidebar" })).toBeInTheDocument()
    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent(
      /Good morning!|Good afternoon!|Good evening!|Welcome back!|Hey!/,
    )
  })

  it("does not expose voice when the browser cannot record audio", () => {
    render(<AskAIPageClient />)

    expect(screen.queryByRole("button", { name: "Start voice input" })).not.toBeInTheDocument()
    expect(screen.getByRole("textbox", { name: "Ask Avana a question" })).toHaveValue("")
  })
})
