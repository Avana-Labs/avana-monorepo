import { lazy, Suspense, type ComponentType, type ReactNode } from "react"
import { cleanup, render, screen, waitFor } from "@testing-library/react"
import { afterEach, expect, it, vi } from "vitest"
import { AskPageClient } from "../ask-page-client"

const state = vi.hoisted(() => ({ authenticated: false, runtimeLoaded: vi.fn(), prefetch: vi.fn() }))
vi.mock("next/navigation", () => ({
  useRouter: () => ({ prefetch: state.prefetch }),
  useSearchParams: () => new URLSearchParams(),
}))
vi.mock("@/app/lib/i18n/use-translation", () => ({ useTranslation: () => ({ t: (text: string) => text }) }))
vi.mock("@/app/lib/siwe/use-siwe-auth", () => ({ useHydrated: () => true }))
vi.mock("../ask-ai-convex-boundary", () => ({
  AskAIConvexBoundary: ({ children }: { children: ReactNode }) =>
    state.authenticated ? children : <div>Starting session</div>,
}))
vi.mock("../ask-ai-page-client", () => {
  state.runtimeLoaded()
  return { AskAIPageClient: () => <div>Chat ready</div> }
})
vi.mock("next/dynamic", () => ({
  default: (loader: () => Promise<ComponentType>, { loading: Loading }: { loading: ComponentType }) => {
    const Runtime = lazy(async () => ({ default: await loader() }))
    return function DynamicRuntime(props: Record<string, unknown>) {
      return (
        <Suspense fallback={<Loading />}>
          <Runtime {...props} />
        </Suspense>
      )
    }
  },
}))
afterEach(cleanup)

it("loads chat code while authentication is pending and renders it after the boundary opens", async () => {
  const { rerender } = render(<AskPageClient />)
  await waitFor(() => expect(state.runtimeLoaded).toHaveBeenCalledTimes(1))
  expect(screen.getByText("Starting session")).toBeInTheDocument()
  expect(screen.queryByText("Chat ready")).not.toBeInTheDocument()
  state.authenticated = true
  rerender(<AskPageClient />)
  expect(await screen.findByText("Chat ready")).toBeInTheDocument()
})
