import { lazy, Suspense, type ComponentType, type ReactNode } from "react"
import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { HomePageWorkspaceRuntime } from "@/app/components/home-page-workspace-runtime"

const { loadAction } = vi.hoisted(() => ({ loadAction: vi.fn() }))

vi.mock("next/dynamic", () => ({
  default: (loader: () => Promise<ComponentType>, options: { loading: ComponentType }) => {
    const Component = lazy(async () => {
      loadAction()
      return { default: await loader() }
    })
    const Loading = options.loading
    return function DynamicAction(props: Record<string, unknown>) {
      return (
        <Suspense fallback={<Loading />}>
          <Component {...props} />
        </Suspense>
      )
    }
  },
}))

vi.mock("@/app/components/home/home-workspace-card", () => ({
  HomeWorkspaceCard: ({ children, onModeChange }: { children: ReactNode; onModeChange: (mode: string) => void }) => (
    <div>
      {["borrow", "repay", "claim", "remove", "swap"].map((mode) => (
        <button key={mode} type="button" onClick={() => onModeChange(mode)}>
          {mode}
        </button>
      ))}
      {children}
    </div>
  ),
}))

vi.mock("@/app/components/home/home-swap-action", () => ({
  HomeSwapAction: () => <div>Swap form</div>,
}))

vi.mock("@/app/components/action-page/borrow-action-page-client", () => ({
  BorrowActionPageClient: ({ kind }: { kind: string }) => <div data-testid="borrow-action">{kind} form</div>,
}))

vi.mock("@/app/lib/avana-session/avana-sessions-provider", () => ({
  AvanaSessionsProvider: ({ children }: { children: ReactNode }) => <>{children}</>,
  useBorrowSessionContext: () => ({ availableCollateralPools: [{ id: "pool" }] }),
  useRewardsSessionContext: () => ({ applyReferralCode: vi.fn(), hasHydratedStorage: false }),
}))

describe("HomePageWorkspaceRuntime", () => {
  it("loads non-swap actions on selection and keeps one homepage shell", async () => {
    const { container } = render(<HomePageWorkspaceRuntime />)

    expect(screen.getByText("Swap form")).toBeInTheDocument()
    expect(loadAction).not.toHaveBeenCalled()
    for (const mode of ["borrow", "repay", "claim", "remove"]) {
      fireEvent.click(screen.getByRole("button", { name: mode }))
      expect(await screen.findByText(`${mode} form`)).toBeInTheDocument()
    }

    expect(loadAction).toHaveBeenCalledTimes(1)
    expect(screen.queryByTestId("home-workspace-loading")).not.toBeInTheDocument()
    expect(container.querySelector(".reveal-in")).toBeNull()
    fireEvent.click(screen.getByRole("button", { name: "swap" }))
    expect(screen.getByText("Swap form")).toBeInTheDocument()
  })
})
