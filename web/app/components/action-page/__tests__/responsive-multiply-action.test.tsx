import { cleanup, render, screen } from "@testing-library/react"
import type { ReactNode } from "react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { ResponsiveMultiplyAction } from "@/app/components/action-page/responsive-multiply-action"

// Controllable viewport: the component embeds the full widget on desktop and falls
// through to a launch CTA on mobile (embedding overflowed the mobile dock).
const { media } = vi.hoisted(() => ({ media: { isDesktop: true } }))
vi.mock("@/app/lib/use-media-query", () => ({
  useMediaQuery: () => media.isDesktop,
}))

vi.mock("@/app/components/action-page/multiply-action-page-client", () => ({
  MultiplyActionPageClient: (props: { kind: string; initialMultiplier?: string }) => (
    <div data-testid="multiply-action-client">
      {props.kind}:{props.initialMultiplier ?? ""}
    </div>
  ),
}))

vi.mock("@/app/components/action-page/detail-sidebar-action-card", () => ({
  DetailSidebarActionCard: ({ children }: { children: ReactNode }) => <div>{children}</div>,
}))

vi.mock("@/app/components/action-page/action-page-launch-cta", () => ({
  ActionPageLaunchCta: () => <div data-testid="launch-cta" />,
}))

describe("ResponsiveMultiplyAction", () => {
  afterEach(() => {
    cleanup()
  })

  it("embeds the multiply action in sidebar mode on desktop", () => {
    media.isDesktop = true
    render(
      <ResponsiveMultiplyAction
        kind="deleverage"
        market="aave-gho"
        closeHref="/multiply/markets/aave-gho"
        sidebar
        initialMultiplier="1.5"
      />,
    )

    expect(screen.getByTestId("multiply-action-client")).toHaveTextContent("deleverage:1.5")
    expect(screen.queryByTestId("launch-cta")).not.toBeInTheDocument()
  })

  it("falls through to the launch CTA on mobile instead of embedding", () => {
    media.isDesktop = false
    render(
      <ResponsiveMultiplyAction
        kind="deleverage"
        market="aave-gho"
        closeHref="/multiply/markets/aave-gho"
        sidebar
        initialMultiplier="1.5"
      />,
    )

    expect(screen.getByTestId("launch-cta")).toBeInTheDocument()
    expect(screen.queryByTestId("multiply-action-client")).not.toBeInTheDocument()
  })
})
