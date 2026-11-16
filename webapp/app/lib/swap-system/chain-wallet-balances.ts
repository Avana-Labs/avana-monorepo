import { formatUnits, keccak256, toHex, type Address, type Hex } from "viem"
import type { SwapAsset, UserAssetBalance } from "./contracts"

/**
 * A wallet's balances on one chain, read from the chain: native ETH and the manifest's ERC-20 tokens (`balanceOf`),
 * and the wallet's LP NFTs that an Avana market accepts. An NFT counts toward a market when it is on the market's
 * position manager with the market's tokens and range, and the market's LPVault `validatePosition` gives its units;
 * an NFT no market accepts is left out. LP rows are one per market: amount in vault tokens, valued at the market's
 * accepted price.
 */

/** What the reader needs from the chain. */
export type BalanceChainClient = {
  readContract(args: {
    address: Address
    abi: readonly unknown[]
    functionName: string
    args?: readonly unknown[]
  }): Promise<unknown>
  getBalance(args: { address: Address }): Promise<bigint>
}

/** One of the chain's tokens, from the manifest (`deployments.swapContractsOf(chainId).tokens`). */
export type ManifestToken = { symbol: string; address: string }

/** The fields of a Convex `markets` row (`collateralMarkets.list`) the reader uses. */
export type BalanceMarket = {
  marketId: string
  slug: string
  name: string
  symbol: string
  tokens: readonly string[]
  tickLower: number
  tickUpper: number
  ammProtocol: string
  vaultToken: string
  vaultDecimals: number
  acceptedPrice: string
  collateralFactorBps: number
}

const ERC20_ABI = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "a", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
] as const

const VAULT_TOKEN_ABI = [
  { type: "function", name: "integration", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const

const LP_VAULT_ABI = [
  {
    type: "function",
    name: "clMarket",
    stateMutability: "view",
    inputs: [{ name: "marketId", type: "uint256" }],
    outputs: [
      {
        type: "tuple",
        components: [
          { name: "pool", type: "address" },
          { name: "positionManager", type: "address" },
          { name: "factory", type: "address" },
          { name: "token0", type: "address" },
          { name: "token1", type: "address" },
          { name: "fee", type: "uint24" },
          { name: "tickSpacing", type: "int24" },
          { name: "tickLower", type: "int24" },
          { name: "tickUpper", type: "int24" },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "validatePosition",
    stateMutability: "view",
    inputs: [
      { name: "marketId", type: "uint256" },
      { name: "owner", type: "address" },
      { name: "positionKey", type: "bytes32" },
    ],
    outputs: [{ type: "uint128" }],
  },
  { type: "function", name: "generationCount", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
  {
    type: "function",
    name: "generation",
    stateMutability: "view",
    inputs: [{ name: "index", type: "uint8" }],
    outputs: [
      { name: "npm", type: "address" },
      { name: "factory", type: "address" },
    ],
  },
] as const

/**
 * `positions(tokenId)` of a Uniswap v3 or Slipstream position manager. Field 4 is the v3 fee (uint24) or the
 * Slipstream tick spacing (int24); it is not read, and both decode as int24.
 */
const POSITION_MANAGER_ABI = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "tokenOfOwnerByIndex",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "index", type: "uint256" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "positions",
    stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [
      { name: "nonce", type: "uint96" },
      { name: "operator", type: "address" },
      { name: "token0", type: "address" },
      { name: "token1", type: "address" },
      { name: "feeOrTickSpacing", type: "int24" },
      { name: "tickLower", type: "int24" },
      { name: "tickUpper", type: "int24" },
      { name: "liquidity", type: "uint128" },
      { name: "feeGrowthInside0LastX128", type: "uint256" },
      { name: "feeGrowthInside1LastX128", type: "uint256" },
      { name: "tokensOwed0", type: "uint128" },
      { name: "tokensOwed1", type: "uint128" },
    ],
  },
] as const

const SLIPSTREAM = keccak256(toHex("AERODROME_SLIPSTREAM")).toLowerCase()
/** Slipstream position key: the position manager's generation index above the token id (`SlipstreamIntegration._key`). */
const GENERATION_SHIFT = 248n

/** The on-chain identity of a market, which never changes once listed; read once per market. */
type MarketBinding = {
  lpVault: Address
  positionManager: Address
  token0: Address
  token1: Address
  tickLower: number
  tickUpper: number
  /** Slipstream only: the generation index of the market's position manager. */
  generation?: number
}

const bindings = new Map<string, Promise<MarketBinding | null>>()
const tokenDecimals = new Map<string, Promise<number | null>>()

const lower = (value: string) => value.toLowerCase()

function marketBinding(
  client: BalanceChainClient,
  chainId: number,
  market: BalanceMarket,
): Promise<MarketBinding | null> {
  const key = `${chainId}:${market.marketId}`
  let read = bindings.get(key)
  if (!read) {
    read = (async (): Promise<MarketBinding | null> => {
      const lpVault = (await client.readContract({
        address: market.vaultToken as Address,
        abi: VAULT_TOKEN_ABI,
        functionName: "integration",
      })) as Address
      const cfg = (await client.readContract({
        address: lpVault,
        abi: LP_VAULT_ABI,
        functionName: "clMarket",
        args: [BigInt(market.marketId)],
      })) as { positionManager: Address; token0: Address; token1: Address; tickLower: number; tickUpper: number }
      const binding: MarketBinding = {
        lpVault,
        positionManager: cfg.positionManager,
        token0: cfg.token0,
        token1: cfg.token1,
        tickLower: Number(cfg.tickLower),
        tickUpper: Number(cfg.tickUpper),
      }
      if (lower(market.ammProtocol) === SLIPSTREAM) {
        const count = Number(
          await client.readContract({ address: lpVault, abi: LP_VAULT_ABI, functionName: "generationCount" }),
        )
        for (let index = 0; index < count; index++) {
          const [npm] = (await client.readContract({
            address: lpVault,
            abi: LP_VAULT_ABI,
            functionName: "generation",
            args: [index],
          })) as readonly [Address, Address]
          if (lower(npm) === lower(cfg.positionManager)) binding.generation = index
        }
        if (binding.generation === undefined) return null
      }
      return binding
    })().catch(() => null)
    read.then((binding) => {
      // A failed read is tried again on the next refresh.
      if (!binding) bindings.delete(key)
    })
    bindings.set(key, read)
  }
  return read
}

function decimalsOf(client: BalanceChainClient, chainId: number, token: Address): Promise<number | null> {
  const key = `${chainId}:${lower(token)}`
  let read = tokenDecimals.get(key)
  if (!read) {
    read = client
      .readContract({ address: token, abi: ERC20_ABI, functionName: "decimals" })
      .then((value) => Number(value))
      .catch(() => null)
    read.then((value) => {
      if (value === null) tokenDecimals.delete(key)
    })
    tokenDecimals.set(key, read)
  }
  return read
}

async function tokenRows(
  client: BalanceChainClient,
  chainId: number,
  wallet: Address,
  tokens: readonly ManifestToken[],
  assets: readonly SwapAsset[],
): Promise<UserAssetBalance[]> {
  const bySymbol = new Map(assets.map((asset) => [asset.symbol.toUpperCase(), asset]))
  const native = assets.find((asset) => asset.isNative)
  const reads: Promise<UserAssetBalance | null>[] = []
  if (native) {
    reads.push(
      client
        .getBalance({ address: wallet })
        .then((units) => row(wallet, native.id, Number(formatUnits(units, native.decimals)))),
    )
  }
  for (const token of tokens) {
    const asset = bySymbol.get(token.symbol.toUpperCase())
    // WETH is listed in the manifest and in the catalog as its own token; native ETH is read above.
    if (asset?.isNative) continue
    reads.push(
      (async () => {
        const decimals = asset?.decimals ?? (await decimalsOf(client, chainId, token.address as Address))
        if (decimals === null) return null
        const units = (await client.readContract({
          address: token.address as Address,
          abi: ERC20_ABI,
          functionName: "balanceOf",
          args: [wallet],
        })) as bigint
        const amount = Number(formatUnits(units, decimals))
        return asset
          ? row(wallet, asset.id, amount)
          : { ...row(wallet, lower(token.symbol), amount), symbol: token.symbol }
      })(),
    )
  }
  const rows = await Promise.all(reads.map((read) => read.catch(() => null)))
  return rows.filter((r): r is UserAssetBalance => r !== null && r.amount > 0)
}

function row(wallet: Address, assetId: string, amount: number): UserAssetBalance {
  const walletId = lower(wallet)
  return { id: `${walletId}:${assetId}:liquid`, walletId, assetId, amount, sourceType: "wallet" }
}

type Nft = { manager: Address; tokenId: bigint; token0: string; token1: string; tickLower: number; tickUpper: number }

async function walletNfts(client: BalanceChainClient, wallet: Address, manager: Address): Promise<Nft[]> {
  const count = (await client.readContract({
    address: manager,
    abi: POSITION_MANAGER_ABI,
    functionName: "balanceOf",
    args: [wallet],
  })) as bigint
  const ids = await Promise.all(
    Array.from(
      { length: Number(count) },
      (_, index) =>
        client.readContract({
          address: manager,
          abi: POSITION_MANAGER_ABI,
          functionName: "tokenOfOwnerByIndex",
          args: [wallet, BigInt(index)],
        }) as Promise<bigint>,
    ),
  )
  return Promise.all(
    ids.map(async (tokenId) => {
      const p = (await client.readContract({
        address: manager,
        abi: POSITION_MANAGER_ABI,
        functionName: "positions",
        args: [tokenId],
      })) as readonly unknown[]
      return {
        manager,
        tokenId,
        token0: lower(p[2] as string),
        token1: lower(p[3] as string),
        tickLower: Number(p[5]),
        tickUpper: Number(p[6]),
      }
    }),
  )
}

function positionKey(binding: MarketBinding, tokenId: bigint): Hex {
  const key = binding.generation === undefined ? tokenId : (BigInt(binding.generation) << GENERATION_SHIFT) | tokenId
  return toHex(key, { size: 32 })
}

async function lpRows(
  client: BalanceChainClient,
  chainId: number,
  wallet: Address,
  markets: readonly BalanceMarket[],
): Promise<UserAssetBalance[]> {
  const bound = (
    await Promise.all(
      markets.map(async (market) => ({ market, binding: await marketBinding(client, chainId, market) })),
    )
  ).filter((entry): entry is { market: BalanceMarket; binding: MarketBinding } => entry.binding !== null)
  const managers = [...new Set(bound.map((entry) => lower(entry.binding.positionManager)))] as Address[]
  const nfts = (
    await Promise.all(managers.map((manager) => walletNfts(client, wallet, manager).catch(() => [] as Nft[])))
  ).flat()

  const walletId = lower(wallet)
  const rows: UserAssetBalance[] = []
  for (const { market, binding } of bound) {
    const matching = nfts.filter(
      (nft) =>
        lower(nft.manager) === lower(binding.positionManager) &&
        nft.token0 === lower(binding.token0) &&
        nft.token1 === lower(binding.token1) &&
        nft.tickLower === binding.tickLower &&
        nft.tickUpper === binding.tickUpper,
    )
    if (matching.length === 0) continue
    const units = await Promise.all(
      matching.map((nft) =>
        (
          client.readContract({
            address: binding.lpVault,
            abi: LP_VAULT_ABI,
            functionName: "validatePosition",
            args: [BigInt(market.marketId), wallet, positionKey(binding, nft.tokenId)],
          }) as Promise<bigint>
        ).catch(() => 0n),
      ),
    )
    const total = units.reduce((sum, value) => sum + value, 0n)
    if (total === 0n) continue
    const amount = Number(formatUnits(total, market.vaultDecimals))
    const unitPriceUsd = Number(BigInt(market.acceptedPrice)) / 1e8
    rows.push({
      id: `${walletId}:${market.slug}:borrow:poolAvailable`,
      walletId,
      assetId: market.slug,
      amount,
      valueUsd: amount * unitPriceUsd,
      symbol: market.symbol,
      name: market.name,
      isLpToken: true,
      unitPriceUsd,
      ltvPct: market.collateralFactorBps / 100,
      sourceType: "borrow_collateral_unpledged",
      sourcePositionId: market.slug,
    })
  }
  return rows
}

/** The wallet's token and LP balances on one chain; a read that fails leaves its rows out. */
export async function readChainWalletBalances({
  client,
  chainId,
  wallet,
  tokens,
  markets,
  assets,
}: {
  client: BalanceChainClient
  chainId: number
  wallet: Address
  tokens: readonly ManifestToken[]
  markets: readonly BalanceMarket[]
  assets: readonly SwapAsset[]
}): Promise<UserAssetBalance[]> {
  const [liquid, lps] = await Promise.all([
    tokenRows(client, chainId, wallet, tokens, assets),
    lpRows(client, chainId, wallet, markets).catch(() => [] as UserAssetBalance[]),
  ])
  return [...liquid, ...lps]
}
