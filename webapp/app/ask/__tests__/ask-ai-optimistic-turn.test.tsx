import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest"

const enqueue = vi.fn()
const emptyQuery: never[] = []
const messagesMock = vi.fn(() => ({ results: emptyQuery, status: "Exhausted", loadMore: vi.fn() }))

vi.mock("convex/react", () => ({
  useQuery: () => emptyQuery,
  usePaginatedQuery: () => ({
    results: [{ threadId: "thread-test", title: "New Chat", status: "active", updatedAt: 1 }],
    status: "Exhausted",
    loadMore: vi.fn(),
  }),
  useMutation: () => enqueue,
}))

vi.mock("@convex-dev/agent/react", () => ({
  useUIMessages: () => messagesMock(),
}))

import { AskAIPageClient } from "../ask-ai-page-client"

beforeAll(() => {
  Object.defineProperty(Element.prototype, "scrollTo", { configurable: true, value: vi.fn() })
})

afterEach(() => {
  cleanup()
  enqueue.mockClear()
  messagesMock.mockReset()
  messagesMock.mockReturnValue({ results: emptyQuery, status: "Exhausted", loadMore: vi.fn() })
})

describe("Ask AI optimistic turn", () => {
  it("edits the middle of a controlled draft without jumping to the end", async () => {
    const user = userEvent.setup()
    render(<AskAIPageClient />)
    const composer = screen.getByLabelText("Ask Avana a question") as HTMLTextAreaElement
    await user.type(composer, "ABCDE")
    composer.setSelectionRange(2, 2)
    await user.keyboard("{Delete}")
    expect(composer).toHaveValue("ABDE")
  })

  it("shows one user bubble before enqueueTurn resolves", async () => {
    let resolveEnqueue!: (value: { turnId: string; promptMessageId: string }) => void
    enqueue.mockImplementation(
      () =>
        new Promise((resolve) => {
          resolveEnqueue = resolve
        }),
    )
    render(<AskAIPageClient />)
    const composer = screen.getByLabelText("Ask Avana a question")
    fireEvent.change(composer, { target: { value: "What is Bitcoin price now?" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    expect(screen.getByText("What is Bitcoin price now?")).toBeInTheDocument()
    expect(screen.getAllByText("What is Bitcoin price now?")).toHaveLength(1)
    expect(enqueue).toHaveBeenCalledTimes(1)
    await act(async () => resolveEnqueue({ turnId: "turn-test", promptMessageId: "message-test" }))
  })

  it("submits immediately from a new draft thread without creating an empty server thread first", async () => {
    let resolveEnqueue!: (value: { turnId: string; promptMessageId: string }) => void
    enqueue
      .mockImplementationOnce(async () => ({ threadId: "thread-new", title: "New Chat" }))
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolveEnqueue = resolve
          }),
      )
    render(<AskAIPageClient />)

    fireEvent.click(screen.getByRole("button", { name: "New Thread" }))
    const composer = screen.getByLabelText("Ask Avana a question")
    fireEvent.change(composer, { target: { value: "Explain Avana liquidation" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    expect(screen.getByText("Explain Avana liquidation")).toBeInTheDocument()
    await waitFor(() => expect(enqueue).toHaveBeenCalledTimes(2))
    await act(async () => resolveEnqueue({ turnId: "turn-new", promptMessageId: "message-new" }))
  })

  it("keeps thinking visible between turn completion state and the assistant subscription", async () => {
    messagesMock.mockReturnValue({
      status: "Exhausted",
      loadMore: vi.fn(),
      results: [
        {
          id: "message-test",
          role: "user",
          text: "How much can I borrow?",
          _creationTime: 1,
          status: "success",
        },
      ],
    })
    enqueue.mockResolvedValue({ turnId: "turn-test", promptMessageId: "message-test" })
    render(<AskAIPageClient />)

    const composer = screen.getByLabelText("Ask Avana a question")
    fireEvent.change(composer, { target: { value: "How much can I borrow?" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    await waitFor(() => expect(enqueue).toHaveBeenCalledTimes(1))
    expect(screen.getByText("Thinking…")).toBeInTheDocument()
  })
})
