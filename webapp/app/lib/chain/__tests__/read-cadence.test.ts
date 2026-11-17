import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { mainnet } from "viem/chains"
import { defineChain } from "viem"
import { MULTICALL3_ADDRESS, withMulticall } from "@/app/lib/chain/public-client"
import { everyWhileVisible } from "@/app/lib/chain/visible-interval"
import { browserRpcProblems, assertBrowserRpc } from "@/app/lib/web3/browser-rpc-guard.mjs"

/** A document whose visibility the test sets, as the browser's `visibilitychange` would. */
function fakeDocument() {
  const target = new EventTarget()
  const doc = Object.assign(target, { visibilityState: "visible" as "visible" | "hidden" })
  const set = (state: "visible" | "hidden") => {
    doc.visibilityState = state
    doc.dispatchEvent(new Event("visibilitychange"))
  }
  return { doc, set }
}

describe("position polling only in visible tabs", () => {
  let page: ReturnType<typeof fakeDocument>

  beforeEach(() => {
    vi.useFakeTimers()
    page = fakeDocument()
    vi.stubGlobal("document", page.doc)
  })
  afterEach(() => {
    vi.useRealTimers()
    vi.unstubAllGlobals()
  })

  it("ticks every interval while visible, not at all while hidden, and once on becoming visible", () => {
    const tick = vi.fn()
    const stop = everyWhileVisible(tick, 15_000)
    vi.advanceTimersByTime(30_000)
    expect(tick).toHaveBeenCalledTimes(2)
    page.set("hidden")
    vi.advanceTimersByTime(60_000)
    expect(tick).toHaveBeenCalledTimes(2)
    page.set("visible")
    expect(tick).toHaveBeenCalledTimes(3)
    stop()
    vi.advanceTimersByTime(60_000)
    page.set("hidden")
    page.set("visible")
    expect(tick).toHaveBeenCalledTimes(3)
  })
})

describe("batched chain reads", () => {
  it("adds Multicall3 to a chain built from env and keeps a known chain's own", () => {
    const local = defineChain({ id: 31337, name: "Ethereum", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } } })
    expect(withMulticall(local).contracts?.multicall3?.address).toBe(MULTICALL3_ADDRESS)
    expect(withMulticall(mainnet)).toBe(mainnet)
  })
})

describe("browser RPC key guard", () => {
  const key = "server-key-1234567890"

  it("refuses a browser URL that carries the services' provider key or repeats a service URL", () => {
    expect(browserRpcProblems({ ALCHEMY_API_KEY: key, NEXT_PUBLIC_RPC_ETHEREUM: `https://eth-sepolia.example/v2/${key}` })).toEqual(["NEXT_PUBLIC_RPC_ETHEREUM contains ALCHEMY_API_KEY"])
    expect(browserRpcProblems({ RPC_BASE_SEPOLIA: "https://base.example/abc", NEXT_PUBLIC_RPC_BASE: "https://base.example/abc" })).toEqual(["NEXT_PUBLIC_RPC_BASE is the same URL as RPC_BASE_SEPOLIA"])
    expect(() => assertBrowserRpc({ QUICKNODE_TOKEN: key, NEXT_PUBLIC_RPC_BASE: `https://x.example/${key}` })).toThrow(/NEXT_PUBLIC_RPC_BASE contains QUICKNODE_TOKEN/)
  })

  it("accepts a separate browser key, a local node and an unset URL, and never prints a value", () => {
    expect(browserRpcProblems({ ALCHEMY_API_KEY: key, NEXT_PUBLIC_RPC_ETHEREUM: "https://eth-sepolia.example/v2/browser-only-key" })).toEqual([])
    expect(browserRpcProblems({ RPC_MAINNET: "http://127.0.0.1:8545", NEXT_PUBLIC_RPC_ETHEREUM: "http://127.0.0.1:8545" })).toEqual([])
    expect(browserRpcProblems({})).toEqual([])
    expect(() => assertBrowserRpc({ ALCHEMY_API_KEY: key, NEXT_PUBLIC_RPC_ETHEREUM: `https://e.example/${key}` })).toThrow(expect.not.objectContaining({ message: expect.stringContaining(key) }))
  })
})
