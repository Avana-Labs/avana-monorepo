import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

// Passthrough translator with {chain} placeholder support, mirroring translate().
vi.mock("@/app/lib/i18n/use-translation", () => ({
  useTranslation: () => ({ t: (key: string) => key, language: "en" }),
}))

const state = {
  isWrongNetwork: false,
  targetChainName: "Ethereum",
  targetChainId: 1,
  isSwitching: false,
  switchError: null as string | null,
  switchToTargetChain: vi.fn(),
}

vi.mock("@/app/lib/web3/use-wrong-network", () => ({
  useWrongNetwork: () => state,
}))

// The banner only reaches wagmi (useWrongNetwork) once the wallet SDK is mounted. Drive the
// gate's `active` flag per-test so we can assert both the mounted UI and the deferred no-op.
const gate = { active: true }
vi.mock("@/app/lib/web3/wallet-gate", () => ({
  useWalletGate: () => gate,
}))

import { WrongNetworkBanner } from "../wrong-network-banner"
import { WrongNetworkBannerInner } from "../wrong-network-banner-inner"

function reset() {
  state.isWrongNetwork = false
  state.isSwitching = false
  state.switchError = null
  state.switchToTargetChain = vi.fn()
  gate.active = true
}

describe("WrongNetworkBanner (gate gating)", () => {
  afterEach(() => {
    cleanup()
    reset()
  })

  it("renders nothing while the wallet SDK is not mounted (guest / deferred)", () => {
    reset()
    gate.active = false
    state.isWrongNetwork = true
    const { container } = render(<WrongNetworkBanner />)
    expect(container.firstChild).toBeNull()
  })

  it("registers a portal slot for the SDK runtime once the wallet SDK is active", async () => {
    reset()
    state.isWrongNetwork = true
    const { container } = render(<WrongNetworkBanner />)
    // The body lives in the wallet runtime (a sibling of the app tree) and is portalled into
    // this slot, so the app tree only ever contains the slot element itself.
    expect(container.firstChild).not.toBeNull()
    const { useWalletSlots } = await import("@/app/lib/web3/wallet-slots")
    function Probe() {
      const slots = useWalletSlots()
      return <output>{slots.map((s) => s.kind).join(",")}</output>
    }
    render(<Probe />)
    expect(await screen.findByText("wrong-network-banner")).toBeInTheDocument()
  })
})

describe("WrongNetworkBannerInner", () => {
  afterEach(() => {
    cleanup()
    reset()
  })

  it("renders nothing on the correct network", () => {
    reset()
    const { container } = render(<WrongNetworkBannerInner />)
    expect(container.firstChild).toBeNull()
  })

  it("shows a switch prompt when on the wrong network", () => {
    reset()
    state.isWrongNetwork = true
    render(<WrongNetworkBannerInner />)
    expect(screen.getByRole("alert")).toBeInTheDocument()
    expect(screen.getByText("Wrong network")).toBeInTheDocument()
    // {chain} placeholder is interpolated with the target chain name.
    expect(screen.getByText("Switch to Ethereum")).toBeInTheDocument()
  })

  it("triggers a chain switch when the button is clicked", () => {
    reset()
    state.isWrongNetwork = true
    const spy = vi.fn()
    state.switchToTargetChain = spy
    render(<WrongNetworkBannerInner />)
    fireEvent.click(screen.getByRole("button", { name: "Switch to Ethereum" }))
    expect(spy).toHaveBeenCalledTimes(1)
  })

  it("disables the button and shows progress while switching", () => {
    reset()
    state.isWrongNetwork = true
    state.isSwitching = true
    render(<WrongNetworkBannerInner />)
    const button = screen.getByRole("button")
    expect(button).toBeDisabled()
    expect(button).toHaveTextContent("Switching…")
  })

  it("surfaces a switch rejection error", () => {
    reset()
    state.isWrongNetwork = true
    state.switchError = "User rejected the request."
    render(<WrongNetworkBannerInner />)
    expect(screen.getByText("User rejected the request.")).toBeInTheDocument()
  })
})
