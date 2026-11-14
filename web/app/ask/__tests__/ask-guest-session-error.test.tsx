import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, expect, it, vi } from "vitest"

vi.stubEnv("NEXT_PUBLIC_CONVEX_URL", "https://example.convex.cloud")
vi.mock("convex/react", () => ({
  ConvexReactClient: class {},
  ConvexProviderWithAuth: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}))
vi.mock("@/app/lib/siwe/auth-store", () => ({ getSiweSession: () => null, fetchSiweAccessToken: vi.fn() }))
vi.mock("@/app/lib/siwe/use-siwe-auth", () => ({ useLiveSiweToken: () => null }))
vi.mock("@/app/lib/ask-ai/guest-auth-store", () => ({
  getAskAIGuestToken: () => null,
  refreshAskAIGuestToken: vi.fn(),
  setAskAIGuestToken: vi.fn(),
  useAskAIGuestToken: () => null,
}))
vi.mock("@/app/lib/i18n/use-translation", () => ({ useTranslation: () => ({ t: (value: string) => value }) }))
vi.mock("../components/ask-ai-skeleton", () => ({ AskAILoadingBody: () => <div>loading</div> }))

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

const respond = (status: number) =>
  vi.fn(async () => new Response(JSON.stringify({ jwt: "t", subject: "s" }), { status }))

it.each([
  [429, "Too many new Ask AI sessions from this network. Try again later."],
  [503, "Ask AI is temporarily unavailable. Try again in a moment."],
])("explains a %s in plain words, without the status code", async (status, copy) => {
  vi.stubGlobal("fetch", respond(status))
  const { AskAIConvexBoundary } = await import("../ask-ai-convex-boundary")
  render(<AskAIConvexBoundary>chat</AskAIConvexBoundary>)
  expect(await screen.findByText(copy)).toBeInTheDocument()
  expect(screen.queryByText(new RegExp(`\\(${status}\\)`))).toBeNull()
})

it("retries the guest session from the error screen", async () => {
  const fetchMock = respond(503)
  vi.stubGlobal("fetch", fetchMock)
  const { AskAIConvexBoundary } = await import("../ask-ai-convex-boundary")
  render(<AskAIConvexBoundary>chat</AskAIConvexBoundary>)
  fireEvent.click(await screen.findByRole("button", { name: "Retry" }))
  await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2))
})
