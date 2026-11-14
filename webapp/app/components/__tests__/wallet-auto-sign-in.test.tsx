import { cleanup, render } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

const state = vi.hoisted(() => ({
  status: "disconnected" as "connecting" | "reconnecting" | "connected" | "disconnected",
  address: undefined as string | undefined,
  isSignedIn: false,
  wrongNetwork: false,
  signIn: vi.fn(async () => undefined),
}))

vi.mock("wagmi", () => ({ useAccount: () => ({ status: state.status, address: state.address }) }))
vi.mock("connectkit", () => ({
  useSIWE: () => ({ isSignedIn: state.isSignedIn, isLoading: false, signIn: state.signIn }),
  ConnectKitButton: { Custom: () => null },
}))
vi.mock("@/app/lib/web3/use-wrong-network", () => ({
  useWrongNetwork: () => ({
    isWrongNetwork: state.wrongNetwork,
    targetChainName: "Ethereum",
    isSwitching: false,
    switchToTargetChain: vi.fn(),
  }),
}))
vi.mock("@/app/lib/web3/wallet-gate", () => ({ useWalletGate: () => ({ consumeAutoOpen: () => false }) }))
vi.mock("@/app/lib/i18n/use-translation", () => ({ useTranslation: () => ({ t: (key: string) => key }) }))

async function mount() {
  const { ConnectedWalletControl } = await import("../wallet-control-connected")
  const desktop = render(<ConnectedWalletControl size="desktop" />)
  const mobile = render(<ConnectedWalletControl size="mobile" />)
  return {
    rerender: () => {
      desktop.rerender(<ConnectedWalletControl size="desktop" />)
      mobile.rerender(<ConnectedWalletControl size="mobile" />)
    },
  }
}

describe("wallet auto sign-in", () => {
  beforeEach(() => {
    vi.resetModules()
    Object.assign(state, { status: "disconnected", address: undefined, isSignedIn: false, wrongNetwork: false })
    state.signIn.mockClear()
  })
  afterEach(cleanup)

  it("prompts the SIWE signature once after the user connects, even with two mounted controls", async () => {
    const view = await mount()
    state.status = "connecting"
    view.rerender()
    Object.assign(state, { status: "connected", address: "0xAbC" })
    view.rerender()
    view.rerender()
    expect(state.signIn).toHaveBeenCalledTimes(1)
  })

  it("waits for a wrong-network switch, then prompts", async () => {
    state.wrongNetwork = true
    const view = await mount()
    state.status = "connecting"
    view.rerender()
    Object.assign(state, { status: "connected", address: "0xAbC" })
    view.rerender()
    expect(state.signIn).not.toHaveBeenCalled()
    state.wrongNetwork = false
    view.rerender()
    expect(state.signIn).toHaveBeenCalledTimes(1)
  })

  it("does not prompt when a session is restored on reload or the wallet is already signed in", async () => {
    state.status = "reconnecting"
    const view = await mount()
    Object.assign(state, { status: "connected", address: "0xAbC" })
    view.rerender()
    expect(state.signIn).not.toHaveBeenCalled()

    Object.assign(state, { status: "connecting", isSignedIn: true })
    view.rerender()
    state.status = "connected"
    view.rerender()
    expect(state.signIn).not.toHaveBeenCalled()
  })
})
