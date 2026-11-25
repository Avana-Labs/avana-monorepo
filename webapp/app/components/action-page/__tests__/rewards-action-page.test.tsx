import { cleanup, render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

const state = vi.hoisted(() => ({
  push: vi.fn(),
  rewards: undefined as unknown,
  redeem: vi.fn(async (..._args: unknown[]): Promise<unknown> => ({
    ok: true,
    points: 1000,
    bps: 2,
    endsAt: 1_900_000_000_000,
  })),
}))

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: state.push }),
  usePathname: () => "/actions/rewards/claim",
}))
vi.mock("@/app/lib/avana-session/avana-sessions-provider", () => ({
  useAvanaSessions: () => ({ walletId: "0x00000000000000000000000000000000000000aa" }),
}))
vi.mock("@/app/lib/rewards/use-wallet-rewards", () => ({ useWalletRewards: () => state.rewards }))
vi.mock("@/app/lib/rewards/redeem-points", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/app/lib/rewards/redeem-points")>()),
  redeemPoints: (...args: unknown[]) => state.redeem(...args),
}))
vi.mock("@/app/lib/i18n/use-translation", () => ({
  useTranslation: () => ({ t: (value: string) => value, language: "EN" }),
}))
vi.mock("@/app/components/action-page/action-flow-header", () => ({ ActionFlowHeader: () => null }))
vi.mock("@/app/components/action-page/processing-narration", () => ({ ProcessingNarration: () => null }))

import { RewardsActionPageClient } from "@/app/components/action-page/rewards-action-page-client"

const RULES = { pointsPerStep: 1000, bpsPerStep: 2, days: 30, maxBps: 2 }
const wallet = (over: Record<string, unknown> = {}) => ({
  earnedPoints: 1300,
  completedQuests: new Set<string>(),
  historyChecked: true,
  availablePoints: 1300,
  redemption: RULES,
  activeRedemptions: [],
  ...over,
})

beforeEach(() => {
  // jsdom does not advance performance.now() inside its rAF loop, so mount animations never settle: finish in one frame.
  vi.stubGlobal(
    "requestAnimationFrame",
    (cb: FrameRequestCallback) => setTimeout(() => cb(performance.now() + 100000), 0) as unknown as number,
  )
  vi.stubGlobal("cancelAnimationFrame", (id: number) => clearTimeout(id as unknown as ReturnType<typeof setTimeout>))
  state.push.mockReset()
  state.redeem.mockClear()
  state.rewards = wallet()
})
afterEach(cleanup)

describe("the redeem page", () => {
  it("shows the loading state until the rewards are known", () => {
    state.rewards = undefined
    render(<RewardsActionPageClient />)
    expect(screen.getByTestId("action-session-loading")).toBeTruthy()
  })

  it("goes configure → review → receipt and redeems one step of points", async () => {
    const user = userEvent.setup()
    render(<RewardsActionPageClient closeHref="/dashboard?tab=wallet" />)
    expect(screen.getAllByText("2 bps off").length).toBeGreaterThan(0)
    await user.click(screen.getByTestId("action-footer-primary"))

    expect(screen.getByTestId("action-review-stage")).toBeTruthy()
    expect(screen.getByText("Review redemption")).toBeTruthy()
    expect(screen.getByText("Valid until")).toBeTruthy()
    await waitFor(() => expect(screen.getByTestId("metric-points-left").textContent).toContain("300 pts"))
    await user.click(screen.getByText("Redeem"))

    await waitFor(() => expect(screen.getByTestId("action-success-stage")).toBeTruthy())
    expect(state.redeem).toHaveBeenCalledWith(1)
    expect(screen.getByText("Redeem successful")).toBeTruthy()
    expect(screen.getByText(/^2 bps off until /)).toBeTruthy()
  })

  it("goes back from the review without redeeming", async () => {
    const user = userEvent.setup()
    render(<RewardsActionPageClient />)
    await user.click(screen.getByTestId("action-footer-primary"))
    await user.click(screen.getByText("Back"))
    expect(screen.queryByTestId("action-review-stage")).toBeNull()
    expect(state.redeem).not.toHaveBeenCalled()
  })

  it("says so when the redemption did not happen, and spends nothing more", async () => {
    state.redeem.mockResolvedValueOnce({ ok: false })
    const user = userEvent.setup()
    render(<RewardsActionPageClient />)
    await user.click(screen.getByTestId("action-footer-primary"))
    await user.click(screen.getByText("Redeem"))
    await waitFor(() => expect(screen.getByText("Could not redeem. Try again.")).toBeTruthy())
    expect(screen.queryByTestId("action-success-stage")).toBeNull()
  })

  it("cannot continue without enough points", async () => {
    state.rewards = wallet({ availablePoints: 400 })
    render(<RewardsActionPageClient />)
    const primary = screen.getByTestId("action-footer-primary") as HTMLButtonElement
    expect(primary.disabled).toBe(true)
    expect(screen.getByText("Not enough points")).toBeTruthy()
  })

  it("cannot continue at the discount limit", () => {
    state.rewards = wallet({ availablePoints: 9000, activeRedemptions: [{ bps: 2, endsAt: 1_900_000_000_000 }] })
    render(<RewardsActionPageClient />)
    expect((screen.getByTestId("action-footer-primary") as HTMLButtonElement).disabled).toBe(true)
    expect(screen.getByText("Discount limit reached")).toBeTruthy()
  })
})
