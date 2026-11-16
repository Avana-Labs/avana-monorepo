import { afterEach, describe, expect, it, vi } from "vitest"
import { chainKey, chainName, defaultChainKey } from "@/app/lib/chains"

describe("chains", () => {
  afterEach(() => {
    vi.unstubAllEnvs()
  })

  it("maps the mainnet chain ids by default", () => {
    expect(chainKey(1)).toBe("ethereum")
    expect(chainKey(8453)).toBe("base")
    expect(chainName(8453)).toBe("Base")
    expect(chainKey(31337)).toBeNull()
    expect(chainKey(undefined)).toBeNull()
  })

  it("takes each chain's id from the environment", () => {
    vi.stubEnv("NEXT_PUBLIC_AVANA_ETHEREUM_CHAIN_ID", "31337")
    vi.stubEnv("NEXT_PUBLIC_AVANA_BASE_CHAIN_ID", "31338")
    expect(chainName(31337)).toBe("Ethereum")
    expect(chainName(31338)).toBe("Base")
    expect(chainKey(1)).toBeNull()
  })

  it("opens on the chain of NEXT_PUBLIC_AVANA_CHAIN_ID, Ethereum otherwise", () => {
    expect(defaultChainKey()).toBe("ethereum")
    vi.stubEnv("NEXT_PUBLIC_AVANA_BASE_CHAIN_ID", "31338")
    vi.stubEnv("NEXT_PUBLIC_AVANA_CHAIN_ID", "31338")
    expect(defaultChainKey()).toBe("base")
    vi.stubEnv("NEXT_PUBLIC_AVANA_CHAIN_ID", "not-a-number")
    expect(defaultChainKey()).toBe("ethereum")
  })
})
