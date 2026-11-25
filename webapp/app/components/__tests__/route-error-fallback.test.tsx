import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

vi.mock("next/link", () => ({
  default: ({ href, children }: { href: string; children: React.ReactNode }) => <a href={href}>{children}</a>,
}))

import { RouteErrorFallback } from "@/app/components/route-error-fallback"

describe("RouteErrorFallback", () => {
  afterEach(() => cleanup())

  it("renders a branded recovery UI with retry and home actions", () => {
    const onRetry = vi.fn()
    render(<RouteErrorFallback onRetry={onRetry} error={new Error("boom")} />)

    expect(screen.getByText("Something went wrong")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Try again" }))
    expect(onRetry).toHaveBeenCalledTimes(1)

    const home = screen.getByRole("link", { name: "Back to dashboard" })
    expect(home).toHaveAttribute("href", "/dashboard")
  })

  it("shows a wallet-reconnect message for auth-shaped errors", () => {
    render(<RouteErrorFallback onRetry={vi.fn()} error={new Error("UNAUTHENTICATED: token expired")} />)

    expect(screen.getByText("Your session needs a refresh")).toBeInTheDocument()
    expect(screen.getByText(/Reconnect your wallet/i)).toBeInTheDocument()
  })

  it("honors custom home href and label", () => {
    render(<RouteErrorFallback onRetry={vi.fn()} homeHref="/borrow" homeLabel="Back to borrow" />)

    expect(screen.getByRole("link", { name: "Back to borrow" })).toHaveAttribute("href", "/borrow")
  })
})
