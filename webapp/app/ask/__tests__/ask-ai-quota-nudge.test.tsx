import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"
import { QuotaNudge } from "../components/ask-ai-thread"

afterEach(cleanup)

describe("Ask AI quota nudge", () => {
  it("stays hidden with five chats left", () => {
    const { container } = render(<QuotaNudge remaining={5} />)
    expect(container).toBeEmptyDOMElement()
  })

  it.each([4, 1])("shows a warm remaining count at %s", (remaining) => {
    render(<QuotaNudge remaining={remaining} />)
    expect(screen.getByText(new RegExp(`you have ${remaining} chat`, "i"))).toBeInTheDocument()
  })

  it("links to Support Center at zero", () => {
    render(<QuotaNudge remaining={0} />)
    expect(screen.getByRole("link", { name: "Open Support Center" })).toHaveAttribute("href", "/support-center")
  })
})
