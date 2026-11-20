import { act, render } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"

vi.mock("@/app/lib/web3/web3-provider", () => ({}))

import { WalletGateProvider, useWalletGate } from "../wallet-gate"

type Gate = ReturnType<typeof useWalletGate>

function setup() {
  const gate: { current: Gate | null } = { current: null }
  function Probe() {
    gate.current = useWalletGate()
    return null
  }
  render(
    <WalletGateProvider>
      <Probe />
    </WalletGateProvider>,
  )
  return gate
}

describe("Get Started opens the wallet modal on the first click", () => {
  it("keeps a click made while the wallet SDK is still loading as an ask to open the modal", async () => {
    const gate = setup()
    act(() => gate.current!.activate())
    // The SDK is loading (a returning session, or a slow chunk): the click must not be lost.
    act(() => gate.current!.connect())
    await act(async () => {})
    expect(gate.current!.active).toBe(true)
    expect(gate.current!.consumeAutoOpen()).toBe(true)
    expect(gate.current!.consumeAutoOpen()).toBe(false)
  })

  it("asks once per click after the SDK mounted, as well as bumping the open request", async () => {
    const gate = setup()
    act(() => gate.current!.connect())
    await act(async () => {})
    expect(gate.current!.consumeAutoOpen()).toBe(true)
    const before = gate.current!.openRequest
    act(() => gate.current!.connect())
    expect(gate.current!.openRequest).toBe(before + 1)
    expect(gate.current!.consumeAutoOpen()).toBe(true)
  })
})
