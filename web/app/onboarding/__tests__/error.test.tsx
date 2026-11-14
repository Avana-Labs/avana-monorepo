import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import OnboardingError from "../error"

// onboarding-flow pulls in wallet-control (connectkit), which doesn't evaluate under
// jsdom — stub it. OnboardingUnavailable itself renders none of it.
vi.mock("@/app/components/wallet-control", () => ({ WalletControl: () => <div /> }))

afterEach(() => cleanup())

describe("OnboardingError boundary (issue #84)", () => {
  it("renders a signed-out prompt (not a generic error) for UNAUTHENTICATED", () => {
    render(<OnboardingError error={new Error("UNAUTHENTICATED: sign in")} reset={() => {}} />)
    expect(screen.getByText(/Reconnect your wallet to continue onboarding/i)).toBeInTheDocument()
  })

  it("renders a generic on-our-side message for a non-auth error", () => {
    render(<OnboardingError error={new Error("boom")} reset={() => {}} />)
    expect(screen.getByText(/We couldn't load onboarding/i)).toBeInTheDocument()
  })

  it("retry calls reset to re-attempt the segment", () => {
    const reset = vi.fn()
    render(<OnboardingError error={new Error("UNAUTHENTICATED")} reset={reset} />)
    fireEvent.click(screen.getByRole("button", { name: /retry/i }))
    expect(reset).toHaveBeenCalledTimes(1)
  })
})
