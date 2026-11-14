import { render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { ActionPageClient } from "@/app/components/action-page/action-page-client"

vi.mock("@/app/components/action-page/borrow-action-page-client", () => ({
  BorrowActionPageClient: ({ kind }: { kind: string }) => <div data-testid="borrow-action-page">{kind}</div>,
}))

vi.mock("@/app/components/action-page/lend-action-page-client", () => ({
  LendActionPageClient: ({ kind }: { kind: string }) => <div data-testid="lend-action-page">{kind}</div>,
}))

vi.mock("@/app/components/action-page/multiply-action-page-client", () => ({
  MultiplyActionPageClient: ({ kind }: { kind: string }) => <div data-testid="multiply-action-page">{kind}</div>,
}))

vi.mock("@/app/components/action-page/rewards-action-page-client", () => ({
  RewardsActionPageClient: () => <div data-testid="rewards-action-page" />,
}))

vi.mock("@/app/components/action-page/umbrella-action-page-client", () => ({
  UmbrellaActionPageClient: ({ kind }: { kind: string }) => <div data-testid="umbrella-action-page">{kind}</div>,
}))

describe("ActionPageClient", () => {
  it("routes borrow product actions", () => {
    render(<ActionPageClient product="borrow" kind="borrow" />)
    expect(screen.getByTestId("borrow-action-page")).toHaveTextContent("borrow")
  })

  it("routes lend product actions", () => {
    render(<ActionPageClient product="lend" kind="deposit" />)
    expect(screen.getByTestId("lend-action-page")).toHaveTextContent("deposit")
  })

  it("routes multiply product actions", () => {
    render(<ActionPageClient product="multiply" kind="deleverage" />)
    expect(screen.getByTestId("multiply-action-page")).toHaveTextContent("deleverage")
  })

  it("routes rewards claim action", () => {
    render(<ActionPageClient product="rewards" kind="claim" />)
    expect(screen.getByTestId("rewards-action-page")).toBeInTheDocument()
  })

  it("routes umbrella product actions", () => {
    render(<ActionPageClient product="umbrella" kind="stake" />)
    expect(screen.getByTestId("umbrella-action-page")).toHaveTextContent("stake")
  })
})
