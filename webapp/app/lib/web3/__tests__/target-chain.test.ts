import { afterEach, describe, expect, it, vi } from "vitest"
import { base, mainnet } from "wagmi/chains"
import { appChain } from "@/app/lib/web3/target-chain"

describe("the app's wallet chains", () => {
  afterEach(() => vi.unstubAllEnvs())

  it("are wagmi's mainnet and base on mainnet", () => {
    vi.stubEnv("NEXT_PUBLIC_AVANA_ETHEREUM_CHAIN_ID", "")
    vi.stubEnv("NEXT_PUBLIC_AVANA_BASE_CHAIN_ID", "")
    vi.stubEnv("NEXT_PUBLIC_RPC_ETHEREUM", "")
    vi.stubEnv("NEXT_PUBLIC_RPC_BASE", "")
    expect(appChain("ethereum")).toBe(mainnet)
    expect(appChain("base")).toBe(base)
  })

  it("on the local forks are built from env, named Ethereum and Base, with their own RPC", () => {
    vi.stubEnv("NEXT_PUBLIC_AVANA_ETHEREUM_CHAIN_ID", "31337")
    vi.stubEnv("NEXT_PUBLIC_AVANA_BASE_CHAIN_ID", "31338")
    vi.stubEnv("NEXT_PUBLIC_RPC_ETHEREUM", "http://127.0.0.1:8545")
    vi.stubEnv("NEXT_PUBLIC_RPC_BASE", "http://127.0.0.1:8546")
    expect(appChain("ethereum")).toMatchObject({ id: 31337, name: "Ethereum", nativeCurrency: { symbol: "ETH" }, rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } } })
    expect(appChain("base")).toMatchObject({ id: 31338, name: "Base", rpcUrls: { default: { http: ["http://127.0.0.1:8546"] } } })
  })

  it("on a testnet need only env", () => {
    vi.stubEnv("NEXT_PUBLIC_AVANA_ETHEREUM_CHAIN_ID", "11155111")
    vi.stubEnv("NEXT_PUBLIC_RPC_ETHEREUM", "https://rpc.example.org")
    expect(appChain("ethereum")).toMatchObject({ id: 11155111, name: "Ethereum", rpcUrls: { default: { http: ["https://rpc.example.org"] } } })
  })
})
