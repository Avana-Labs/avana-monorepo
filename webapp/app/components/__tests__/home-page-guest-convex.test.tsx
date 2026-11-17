import { render, screen } from "@testing-library/react"
import { renderToString } from "react-dom/server"
import { describe, expect, it, vi } from "vitest"

// A deployment URL makes `hasConvexClient` true (read once at module load), while the guest home renders
// outside every ConvexProvider. Convex's `useQuery` is left real so a call without a provider throws.
vi.hoisted(() => {
  process.env.NEXT_PUBLIC_CONVEX_URL = "https://guest-home.convex.cloud"
})
vi.mock("@/app/lib/siwe/use-siwe-auth", () => ({
  useSiweAuth: () => ({ authedWallet: null, isSignedIn: false }),
}))

import { hasConvexClient } from "@/app/lib/convex/has-convex-client"
import { HomePageClient } from "../home-page-client"

describe("guest home with a Convex deployment", () => {
  it("has a Convex deployment configured", () => {
    expect(hasConvexClient).toBe(true)
  })

  it("renders on the server without a ConvexProvider", () => {
    expect(() => renderToString(<HomePageClient />)).not.toThrow()
  })

  it("renders the guest swap workspace in the browser without a ConvexProvider", () => {
    expect(() => render(<HomePageClient />)).not.toThrow()
    expect(screen.getByRole("heading", { name: "Avana workspace" })).toBeInTheDocument()
  })
})
