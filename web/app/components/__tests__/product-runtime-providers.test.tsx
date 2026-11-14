import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

const state = vi.hoisted(() => ({ pathname: "/", isSignedIn: false }))

vi.mock("next/navigation", () => ({ usePathname: () => state.pathname }))
vi.mock("@/app/lib/siwe/use-siwe-auth", () => ({ useSiweAuth: () => ({ isSignedIn: state.isSignedIn }) }))
vi.mock("@/app/lib/test-mode", () => ({ shouldUseOpenGateSession: () => false }))
vi.mock("next/dynamic", () => ({
  default: () =>
    function SessionProviders({ children }: { children: React.ReactNode }) {
      return <div data-testid="session-providers">{children}</div>
    },
}))
vi.mock("@/app/components/preferences-profile-sync", () => ({ PreferencesProfileSync: () => null }))
vi.mock("@/app/lib/prices/token-prices-context", () => ({
  TokenPricesProvider: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}))

import { ProductRuntimeProviders } from "../product-runtime-providers"

afterEach(() => cleanup())

describe("ProductRuntimeProviders for guests", () => {
  it.each(["/", "/borrow", "/lend/markets/usdc", "/swap"])("selects the required session runtime on %s", (pathname) => {
    state.pathname = pathname
    render(<ProductRuntimeProviders>page</ProductRuntimeProviders>)
    if (pathname === "/") {
      expect(screen.queryByTestId("session-providers")).toBeNull()
      expect(screen.getByText("page")).toBeInTheDocument()
    } else {
      expect(screen.getByTestId("session-providers")).toHaveTextContent("page")
    }
  })

  it("leaves guest /ask on its own Convex boundary", () => {
    state.pathname = "/ask"
    render(<ProductRuntimeProviders>page</ProductRuntimeProviders>)
    expect(screen.queryByTestId("session-providers")).toBeNull()
  })
})
