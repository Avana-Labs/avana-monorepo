import { describe, expect, it } from "vitest"
import { keccak256, toHex, type Address } from "viem"
import { readChainWalletBalances, type BalanceChainClient, type BalanceMarket } from "../chain-wallet-balances"
import type { SwapAsset } from "../contracts"

const WALLET = "0x00000000000000000000000000000000000000aa" as Address
const USDC = "0x0000000000000000000000000000000000000c01"
const WETH = "0x0000000000000000000000000000000000000c02"
const AERO = "0x0000000000000000000000000000000000000c03"
const V3_NPM = "0x0000000000000000000000000000000000000d01"
const SLIP_NPM = "0x0000000000000000000000000000000000000d02"
const V3_VAULT = "0x0000000000000000000000000000000000000e01"
const SLIP_VAULT = "0x0000000000000000000000000000000000000e02"
const VT_A = "0x0000000000000000000000000000000000000f01"
const VT_B = "0x0000000000000000000000000000000000000f02"

const asset = (id: string, symbol: string, decimals: number, isNative = false): SwapAsset => ({
  id,
  chainId: 31337,
  symbol,
  name: symbol,
  decimals,
  assetType: isNative ? "native" : "erc20",
  isNative,
  isLpToken: false,
  isSwapEnabled: true,
  priceUsd: 0,
  minimumSwapAmount: 0,
  maximumSwapAmount: 1,
})
const ASSETS = [asset("eth", "ETH", 18, true), asset("usdc", "USDC", 6), asset("weth", "WETH", 18)]

const market = (over: Partial<BalanceMarket>): BalanceMarket => ({
  marketId: "1",
  slug: "weth-usdc-v3",
  name: "WETH / USDC",
  symbol: "WETH/USDC",
  tokens: [USDC, WETH],
  tickLower: -600,
  tickUpper: 600,
  ammProtocol: keccak256(toHex("UNISWAP_V3")),
  vaultToken: VT_A,
  vaultDecimals: 6,
  acceptedPrice: "250000000", // $2.50 per vault token
  collateralFactorBps: 7650,
  ...over,
})

type Nft = { id: bigint; token0: string; token1: string; tickLower: number; tickUpper: number }

/** A chain with balances, two NFT managers and two LPVaults; `units` maps `${vault}:${marketId}:${key}` to units. */
function fakeChain({
  nfts,
  units,
}: {
  nfts: Record<string, Nft[]>
  units: Record<string, bigint>
}): BalanceChainClient {
  const bindings: Record<string, { vault: string; npm: string }> = {
    [VT_A]: { vault: V3_VAULT, npm: V3_NPM },
    [VT_B]: { vault: SLIP_VAULT, npm: SLIP_NPM },
  }
  return {
    getBalance: async () => 2n * 10n ** 18n,
    readContract: async ({ address, functionName, args = [] }) => {
      const a = address.toLowerCase()
      if (functionName === "balanceOf" && a === USDC) return 1_500_000_000n
      if (functionName === "balanceOf" && a === WETH) return 0n
      if (functionName === "balanceOf" && a === AERO) return 3n * 10n ** 17n
      if (functionName === "decimals" && a === AERO) return 18
      if (functionName === "integration") return bindings[a]!.vault
      if (functionName === "clMarket") {
        const npm = a === V3_VAULT ? V3_NPM : SLIP_NPM
        return { positionManager: npm, token0: USDC, token1: WETH, tickLower: -600, tickUpper: 600 }
      }
      if (functionName === "generationCount") return 2
      if (functionName === "generation")
        return [args[0] === 1 ? SLIP_NPM : "0x0000000000000000000000000000000000000d99", AERO]
      if (functionName === "balanceOf") return BigInt(nfts[a]?.length ?? 0)
      if (functionName === "tokenOfOwnerByIndex") return nfts[a]![Number(args[1])]!.id
      if (functionName === "positions") {
        const n = nfts[a]!.find((x) => x.id === args[0])!
        return [0n, WALLET, n.token0, n.token1, 0, n.tickLower, n.tickUpper, 1n, 0n, 0n, 0n, 0n]
      }
      if (functionName === "validatePosition") {
        const value = units[`${a}:${args[0]}:${args[2]}`]
        if (value === undefined) throw new Error("PoolMismatch")
        return value
      }
      throw new Error(`unexpected ${functionName} on ${a}`)
    },
  }
}

const key = (n: bigint) => toHex(n, { size: 32 })

describe("readChainWalletBalances", () => {
  it("reads native ETH and manifest tokens, skipping zero balances", async () => {
    const rows = await readChainWalletBalances({
      client: fakeChain({ nfts: {}, units: {} }),
      chainId: 31337,
      wallet: WALLET,
      tokens: [
        { symbol: "USDC", address: USDC },
        { symbol: "WETH", address: WETH },
        { symbol: "AERO", address: AERO },
      ],
      markets: [],
      assets: ASSETS,
    })
    expect(rows).toEqual([
      { id: `${WALLET}:eth:liquid`, walletId: WALLET, assetId: "eth", amount: 2, sourceType: "wallet" },
      { id: `${WALLET}:usdc:liquid`, walletId: WALLET, assetId: "usdc", amount: 1500, sourceType: "wallet" },
      {
        id: `${WALLET}:aero:liquid`,
        walletId: WALLET,
        assetId: "aero",
        amount: 0.3,
        sourceType: "wallet",
        symbol: "AERO",
      },
    ])
  })

  it("sums a market's accepted NFTs into one LP row and leaves out NFTs no market accepts", async () => {
    const rows = await readChainWalletBalances({
      client: fakeChain({
        nfts: {
          [V3_NPM]: [
            { id: 7n, token0: USDC, token1: WETH, tickLower: -600, tickUpper: 600 },
            { id: 8n, token0: USDC, token1: WETH, tickLower: -600, tickUpper: 600 },
            // Another range: no market.
            { id: 9n, token0: USDC, token1: WETH, tickLower: -60, tickUpper: 60 },
            // Same range but the vault rejects it (e.g. another fee tier's pool).
            { id: 10n, token0: USDC, token1: WETH, tickLower: -600, tickUpper: 600 },
          ],
        },
        units: { [`${V3_VAULT}:1:${key(7n)}`]: 1_000_000n, [`${V3_VAULT}:1:${key(8n)}`]: 3_000_000n },
      }),
      chainId: 31337,
      wallet: WALLET,
      tokens: [],
      markets: [market({})],
      assets: ASSETS,
    })
    expect(rows.filter((r) => r.isLpToken)).toEqual([
      {
        id: `${WALLET}:weth-usdc-v3:borrow:poolAvailable`,
        walletId: WALLET,
        assetId: "weth-usdc-v3",
        amount: 4,
        valueUsd: 10,
        symbol: "WETH/USDC",
        name: "WETH / USDC",
        isLpToken: true,
        unitPriceUsd: 2.5,
        ltvPct: 76.5,
        sourceType: "borrow_collateral_unpledged",
        sourcePositionId: "weth-usdc-v3",
      },
    ])
  })

  it("keys a Slipstream NFT by its position manager's generation", async () => {
    const generationKey = toHex((1n << 248n) | 5n, { size: 32 })
    const rows = await readChainWalletBalances({
      client: fakeChain({
        nfts: { [SLIP_NPM]: [{ id: 5n, token0: USDC, token1: WETH, tickLower: -600, tickUpper: 600 }] },
        units: { [`${SLIP_VAULT}:2:${generationKey}`]: 500_000n },
      }),
      chainId: 31338,
      wallet: WALLET,
      tokens: [],
      markets: [
        market({
          marketId: "2",
          slug: "weth-usdc-slip",
          vaultToken: VT_B,
          ammProtocol: keccak256(toHex("AERODROME_SLIPSTREAM")),
        }),
      ],
      assets: ASSETS,
    })
    expect(rows.filter((r) => r.isLpToken).map((r) => [r.assetId, r.amount, r.valueUsd])).toEqual([
      ["weth-usdc-slip", 0.5, 1.25],
    ])
  })
})
