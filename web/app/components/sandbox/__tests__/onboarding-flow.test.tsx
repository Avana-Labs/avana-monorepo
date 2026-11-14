import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { OnboardingFlow, type OnboardingGateState } from "../onboarding-flow"

// The onboarding mutations, keyed by the api reference `useMutation` is called with. Each
// test inspects these spies to assert which advance mutation the flow (auto-)invoked.
const startAnalysis = vi.fn().mockResolvedValue("eligible")
const beginAnalysis = vi.fn().mockResolvedValue("analyzing")
const beginClaim = vi.fn().mockResolvedValue("claimPending")
const claim = vi.fn().mockResolvedValue({ status: "done", allocatedUsd: 1_000_000 })
const noop = vi.fn().mockResolvedValue(undefined)
let walletProfile: { preferences?: { name?: string; dexSources?: string[] } } | null = null

vi.mock("convex/react", () => ({
  useQuery: () => walletProfile,
  useMutation: (ref: { fn: () => unknown }) => {
    const name = String(ref?.fn ?? "")
    if (name.includes("startAnalysis")) return startAnalysis
    if (name.includes("beginAnalysis")) return beginAnalysis
    if (name.includes("beginClaim")) return beginClaim
    if (name.includes("claim")) return claim
    return noop
  },
}))

// Identify each mutation by a stable stringifiable marker, so the useMutation mock above
// can route to the right spy (convex's real api objects aren't stringifiable in jsdom).
vi.mock("@/convex/_generated/api", () => ({
  api: {
    sandbox: {
      onboarding: {
        beginAnalysis: { fn: () => "beginAnalysis" },
        startAnalysis: { fn: () => "startAnalysis" },
        startTweet: { fn: () => "startTweet" },
        confirmTweet: { fn: () => "confirmTweet" },
        skipTweet: { fn: () => "skipTweet" },
        beginClaim: { fn: () => "beginClaim" },
        claim: { fn: () => "claim" },
      },
    },
    wallet: { profiles: { getMine: { fn: () => "getMine" }, savePreferences: { fn: () => "savePreferences" } } },
  },
}))

vi.mock("@/app/lib/i18n/use-translation", () => ({
  useTranslation: () => ({ t: (s: string) => s, language: "en" }),
}))

vi.mock("@/app/components/wallet-control", () => ({
  WalletControl: () => <div data-testid="wallet-control" />,
}))

const WALLET = "0xabc0000000000000000000000000000000000001"

function stateWithStep(
  step: OnboardingGateState["onboardingStep"],
  config?: Partial<OnboardingGateState["config"]>,
): OnboardingGateState {
  return {
    onboardingStep: step,
    profile: { eligibilityTier: 1 },
    config: { basket: [], tweetTemplate: "", xHandle: "", resourcesLinks: [], ...config },
    economy: { status: "open", userCount: 1, userCap: 10, perUserTargetUsd: 1_000_000 },
  }
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  walletProfile = null
})

describe("OnboardingFlow — stranded loading recovery (issue #83)", () => {
  it("auto-resumes when reloaded stranded in 'analyzing' (no active task)", async () => {
    render(<OnboardingFlow wallet={WALLET} state={stateWithStep("analyzing")} />)
    // The persisted loading step has no client task driving it, so the flow must re-invoke
    // the advance mutation itself rather than spin forever.
    await waitFor(() => expect(startAnalysis).toHaveBeenCalledWith({ wallet: WALLET }))
  })

  it("auto-resumes when reloaded stranded in 'claimPending' (no active task)", async () => {
    render(<OnboardingFlow wallet={WALLET} state={stateWithStep("claimPending")} />)
    await waitFor(() => expect(beginClaim).toHaveBeenCalledWith({ wallet: WALLET }))
  })

  it("always shows a manual continue control on a loading screen (not gated on an error)", () => {
    render(<OnboardingFlow wallet={WALLET} state={stateWithStep("analyzing")} />)
    // A recovery affordance is present even though no error has occurred — so a stuck
    // spinner is never a dead end. (AnimatePresence may keep an exiting copy mounted, so
    // assert at least one is present rather than exactly one.)
    expect(screen.getAllByText(/Taking longer than expected/i).length).toBeGreaterThan(0)
  })

  it("does not offer resume on a non-loading step", () => {
    render(<OnboardingFlow wallet={WALLET} state={stateWithStep("eligible")} />)
    expect(screen.queryByText(/Taking longer than expected/i)).not.toBeInTheDocument()
    expect(startAnalysis).not.toHaveBeenCalled()
  })
})

describe("OnboardingFlow — Convex config drives the UI (issue #139)", () => {
  it("renders the Convex tweetTemplate in the share sub-flow and its X intent href", () => {
    render(
      <OnboardingFlow
        wallet={WALLET}
        state={stateWithStep("xPending", { tweetTemplate: "Practicing DeFi on Avana", xHandle: "AvanaFinance" })}
      />,
    )
    // The fetched template (not the hardcoded launch copy) is what the user sees + posts.
    expect(screen.getByText(/Practicing DeFi on Avana/)).toBeInTheDocument()
    expect(screen.getByText(/@AvanaFinance/)).toBeInTheDocument()
    const openX = screen.getByRole("link", { name: /Open X/i }) as HTMLAnchorElement
    expect(decodeURIComponent(openX.href)).toContain("Practicing DeFi on Avana")
    expect(decodeURIComponent(openX.href)).toContain("@AvanaFinance")
  })

  it("falls back to the launch copy when the config carries no tweetTemplate", () => {
    render(<OnboardingFlow wallet={WALLET} state={stateWithStep("xPending")} />)
    expect(screen.getByText(/Just claimed my sandbox spot at Avana/)).toBeInTheDocument()
  })
})

describe("OnboardingFlow — personalize + liquidity-source steps", () => {
  it("runs personalize → liquidity → funding, capping the name and saving DEX sources", async () => {
    render(<OnboardingFlow wallet={WALLET} state={stateWithStep("wallet")} />)

    // A fresh wallet lands on the personalize step first (not the funding card).
    expect(screen.getByText(/Now let's make Avana yours/i)).toBeInTheDocument()
    const nameInput = screen.getByPlaceholderText(/Your name/i)
    expect(nameInput).toHaveAttribute("maxLength", "10")
    expect(screen.getByRole("button", { name: /^Continue$/i })).toBeDisabled()
    fireEvent.change(nameInput, { target: { value: "ElizabethAlexandra" } })
    expect(screen.getByRole("button", { name: /^Continue$/i })).toBeEnabled()
    fireEvent.click(screen.getByRole("button", { name: /^Continue$/i }))

    // The save is capped at 10 chars regardless of the raw input length.
    await waitFor(() =>
      expect(noop).toHaveBeenCalledWith(
        expect.objectContaining({ preferences: expect.objectContaining({ name: "ElizabethA" }) }),
      ),
    )

    // Advances to the liquidity-source multi-select.
    await screen.findByText(/Which DEXs do you use the most/i)
    fireEvent.click(screen.getByRole("button", { name: /Uniswap/i }))
    fireEvent.click(screen.getByRole("button", { name: /^Continue$/i }))

    await waitFor(() =>
      expect(noop).toHaveBeenCalledWith(expect.objectContaining({ preferences: { dexSources: ["uniswap"] } })),
    )

    // Then the original funding card.
    await screen.findByText(/Let's fund your sandbox/i)
  })

  it("skips both steps for a wallet that has already saved preferences", () => {
    const state = stateWithStep("wallet")
    walletProfile = { preferences: { name: "Sam", dexSources: ["uniswap"] } }
    render(<OnboardingFlow wallet={WALLET} state={state} />)

    expect(screen.getByText(/Let's fund your sandbox/i)).toBeInTheDocument()
    expect(screen.queryByText(/make Avana yours/i)).not.toBeInTheDocument()
  })
})
