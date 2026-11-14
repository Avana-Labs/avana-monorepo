import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import SyntheticTransactionError from "../error"

afterEach(() => cleanup())

describe("SyntheticTransactionError boundary (issue #84)", () => {
  it("renders a graceful signed-out prompt (not a generic error) for WALLET_MISMATCH", () => {
    render(<SyntheticTransactionError error={new Error("WALLET_MISMATCH")} reset={() => {}} />)
    expect(screen.getByText(/Sign in with the wallet that created this transaction/i)).toBeInTheDocument()
  })

  it("renders a generic message for a non-auth error", () => {
    render(<SyntheticTransactionError error={new Error("boom")} reset={() => {}} />)
    expect(screen.getByText(/We couldn't load this receipt right now/i)).toBeInTheDocument()
  })

  it("retry calls reset to re-attempt the segment", () => {
    const reset = vi.fn()
    render(<SyntheticTransactionError error={new Error("UNAUTHENTICATED")} reset={reset} />)
    fireEvent.click(screen.getByRole("button", { name: /try again/i }))
    expect(reset).toHaveBeenCalledTimes(1)
  })
})
