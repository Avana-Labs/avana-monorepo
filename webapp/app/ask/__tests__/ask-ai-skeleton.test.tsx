import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"
import { AskAILoadingBody } from "@/app/ask/components/ask-ai-skeleton"

afterEach(cleanup)

describe("Ask AI loading body", () => {
  it("shows one first-visit shell without chat bubbles or interim copy", () => {
    const { container } = render(<AskAILoadingBody />)

    expect(screen.getByTestId("ask-ai-loading-body")).toBeInTheDocument()
    expect(screen.getByTestId("ask-ai-empty-thread-skeleton")).toBeInTheDocument()
    expect(screen.queryByTestId("ask-ai-thread-skeleton")).not.toBeInTheDocument()
    expect(screen.queryByText("Loading conversations")).not.toBeInTheDocument()
    expect(screen.queryByText("No threads yet")).not.toBeInTheDocument()
    expect(container.querySelectorAll(".skeleton-shimmer").length).toBeGreaterThan(8)
  })

  it("keeps the composer with the greeting instead of pinning it to the bottom", () => {
    render(<AskAILoadingBody />)

    const empty = screen.getByTestId("ask-ai-empty-thread-skeleton")
    const column = empty.parentElement
    expect(column).toHaveClass("justify-center")
    expect(column?.querySelector(".mt-auto")).not.toBeInTheDocument()
  })
})
