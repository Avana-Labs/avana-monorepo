import { describe, expect, it } from "vitest"
import type { WalletLpPosition } from "@/app/lib/swap-system/chain-wallet-balances"
import { pledgeableFromWallet } from "@/app/lib/borrow-system/pledgeable-lps"

const NPM = "0x00000000000000000000000000000000000000e2"
const VAULT = "0x00000000000000000000000000000000000000e3"
const row = (tokenId: bigint, market: WalletLpPosition["market"]): WalletLpPosition => ({
  chainId: 31338,
  venue: "slipstream",
  npm: NPM,
  tokenId,
  positionKey: `0x01${tokenId.toString(16).padStart(62, "0")}`,
  token0: "0x00000000000000000000000000000000000000a1",
  token1: "0x00000000000000000000000000000000000000a2",
  pair: "WETH / USDC",
  pool: null,
  market,
})

describe("pledgeableFromWallet", () => {
  it("keeps the NFTs a market accepts, with the market's id, vault and value", () => {
    const market = { marketId: "4", poolSlug: "weth-usdc-100", integrationId: 2, lpVault: VAULT, units: 9n, valueUsd6: 43_750_000_000n } as const
    const out = pledgeableFromWallet([row(5n, market), row(6n, null)])
    expect(out).toEqual([
      {
        chainId: 31338,
        marketId: "4",
        integrationId: 2,
        positionKey: `0x01${(5n).toString(16).padStart(62, "0")}`,
        npm: NPM,
        tokenId: 5n,
        lpVault: VAULT,
        valueUsd6: 43_750_000_000n,
      },
    ])
  })
})
