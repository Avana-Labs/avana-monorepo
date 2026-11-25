import { formatUnits, keccak256, toHex, type Address, type Hex } from "viem"
import type { SwapAsset, UserAssetBalance } from "./contracts"

/**
 * A wallet's balances on one chain, read from the chain: native ETH and the manifest's ERC-20 tokens (`balanceOf`),
 * and the wallet's LP NFTs on the position managers Avana's LPVaults are bound to. An NFT belongs to a market when it
 * is on the market's position manager with the market's tokens and range, and the market's LPVault
 * `validatePosition` gives its units. Wallet-tab LP rows are one per market (amount in vault tokens, valued at the
 * market's accepted price) and one per NFT no market accepts, shown as unsupported.
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
  integrationId: number
  vaultToken: string
  vaultDecimals: number
  acceptedPrice: string
  collateralFactorBps: number
}

/** The venues whose position managers the reader knows. */
export type LpVenue = "uniswap-v3" | "slipstream"

const ERC20_ABI = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "a", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
  { type: "function", name: "symbol", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
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
 * A Uniswap v3 or Slipstream position manager. In `positions(tokenId)`, field 4 is the v3 fee (uint24) or the
 * Slipstream tick spacing (int24); both decode as int24.
 */
const POSITION_MANAGER_ABI = [
  { type: "function", name: "factory", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
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

/** Uniswap v3 `getPool(tokenA, tokenB, fee)` and Slipstream `getPool(tokenA, tokenB, tickSpacing)` encode alike. */
const FACTORY_ABI = [
  {
    type: "function",
    name: "getPool",
    stateMutability: "view",
    inputs: [
      { name: "tokenA", type: "address" },
      { name: "tokenB", type: "address" },
      { name: "feeOrTickSpacing", type: "int24" },
    ],
    outputs: [{ type: "address" }],
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
  venue: LpVenue
  /** Every position manager the market's LPVault is bound to (each Slipstream generation). */
  managers: readonly { npm: Address; generation?: number }[]
}

const bindings = new Map<string, Promise<MarketBinding | null>>()
const tokenDecimals = new Map<string, Promise<number | null>>()
const tokenSymbols = new Map<string, Promise<string | null>>()
const poolAddresses = new Map<string, Promise<Address | null>>()

const lower = (value: string) => value.toLowerCase()

/** A cached read: kept once it succeeds, read again after a failure. */
function cached<T>(
  cache: Map<string, Promise<T | null>>,
  key: string,
  read: () => Promise<T | null>,
): Promise<T | null> {
  let entry = cache.get(key)
  if (!entry) {
    entry = read().catch(() => null)
    void entry.then((value) => {
      if (value === null) cache.delete(key)
    })
    cache.set(key, entry)
  }
  return entry
}

function marketBinding(
  client: BalanceChainClient,
  chainId: number,
  market: BalanceMarket,
): Promise<MarketBinding | null> {
  return cached(bindings, `${chainId}:${market.marketId}`, async () => {
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
    const base = {
      lpVault,
      positionManager: cfg.positionManager,
      token0: cfg.token0,
      token1: cfg.token1,
      tickLower: Number(cfg.tickLower),
      tickUpper: Number(cfg.tickUpper),
    }
    if (lower(market.ammProtocol) !== SLIPSTREAM) {
      return { ...base, venue: "uniswap-v3", managers: [{ npm: cfg.positionManager }] }
    }
    const count = Number(
      await client.readContract({ address: lpVault, abi: LP_VAULT_ABI, functionName: "generationCount" }),
    )
    const managers = await Promise.all(
      Array.from({ length: count }, async (_, index) => {
        const [npm] = (await client.readContract({
          address: lpVault,
          abi: LP_VAULT_ABI,
          functionName: "generation",
          args: [index],
        })) as readonly [Address, Address]
        return { npm, generation: index }
      }),
    )
    if (!managers.some((m) => lower(m.npm) === lower(cfg.positionManager))) return null
    return { ...base, venue: "slipstream", managers }
  })
}

function decimalsOf(client: BalanceChainClient, chainId: number, token: Address): Promise<number | null> {
  return cached(tokenDecimals, `${chainId}:${lower(token)}`, async () =>
    Number(await client.readContract({ address: token, abi: ERC20_ABI, functionName: "decimals" })),
  )
}

function symbolOf(client: BalanceChainClient, chainId: number, token: Address): Promise<string | null> {
  return cached(tokenSymbols, `${chainId}:${lower(token)}`, async () =>
    String(await client.readContract({ address: token, abi: ERC20_ABI, functionName: "symbol" })),
  )
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

type Nft = {
  manager: Address
  tokenId: bigint
  token0: Address
  token1: Address
  feeOrTickSpacing: number
  tickLower: number
  tickUpper: number
  liquidity: bigint
}

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
        token0: lower(p[2] as string) as Address,
        token1: lower(p[3] as string) as Address,
        feeOrTickSpacing: Number(p[4]),
        tickLower: Number(p[5]),
        tickUpper: Number(p[6]),
        liquidity: p[7] as bigint,
      }
    }),
  )
}

/** The pool of an NFT: `factory.getPool(token0, token1, feeOrTickSpacing)` on its position manager's factory. */
function poolOf(client: BalanceChainClient, chainId: number, nft: Nft): Promise<Address | null> {
  const key = `${chainId}:${lower(nft.manager)}:${nft.token0}:${nft.token1}:${nft.feeOrTickSpacing}`
  return cached(poolAddresses, key, async () => {
    const factory = (await client.readContract({
      address: nft.manager,
      abi: POSITION_MANAGER_ABI,
      functionName: "factory",
    })) as Address
    const pool = (await client.readContract({
      address: factory,
      abi: FACTORY_ABI,
      functionName: "getPool",
      args: [nft.token0, nft.token1, nft.feeOrTickSpacing],
    })) as Address
    return /^0x0{40}$/i.test(pool) ? null : pool
  })
}

/** 10^n as a bigint. */
function pow10(n: number): bigint {
  return BigInt(`1${"0".repeat(n)}`)
}

function positionKeyOf(generation: number | undefined, tokenId: bigint): Hex {
  const key = generation === undefined ? tokenId : (BigInt(generation) << GENERATION_SHIFT) | tokenId
  return toHex(key, { size: 32 })
}

/**
 * One LP NFT with liquidity that the wallet holds on a position manager an Avana LPVault is bound to. `market` is set
 * when a market accepts it (its LPVault `validatePosition` passed), and the NFT can be pledged there; otherwise the
 * NFT is unsupported and cannot be pledged.
 */
export type WalletLpPosition = {
  chainId: number
  venue: LpVenue
  npm: Address
  tokenId: bigint
  /** Slipstream: the generation index in the top byte (`SlipstreamIntegration._key`); Uniswap v3: the token id. */
  positionKey: Hex
  token0: Address
  token1: Address
  /** "WETH / USDC", from the tokens' `symbol()`. */
  pair: string
  /** The pool; null when the NFT is in a market (not read) or the factory does not know it. */
  pool: Address | null
  market: {
    marketId: string
    poolSlug: string
    integrationId: number
    lpVault: Address
    units: bigint
    /** The NFT at the market's accepted price, USD with 6 decimals. */
    valueUsd6: bigint
  } | null
}

/** The wallet's LP NFTs on one chain, each with the market that accepts it, if any. */
export async function readWalletLpPositions({
  client,
  chainId,
  wallet,
  markets,
}: {
  client: BalanceChainClient
  chainId: number
  wallet: Address
  markets: readonly BalanceMarket[]
}): Promise<WalletLpPosition[]> {
  const bound = (
    await Promise.all(
      markets.map(async (market) => ({ market, binding: await marketBinding(client, chainId, market) })),
    )
  ).filter((entry): entry is { market: BalanceMarket; binding: MarketBinding } => entry.binding !== null)

  const managers = new Map<string, { npm: Address; venue: LpVenue; generation?: number }>()
  for (const { binding } of bound) {
    for (const m of binding.managers) {
      managers.set(lower(m.npm), { npm: m.npm, venue: binding.venue, generation: m.generation })
    }
  }
  const nfts = (
    await Promise.all([...managers.values()].map((m) => walletNfts(client, wallet, m.npm).catch(() => [] as Nft[])))
  )
    .flat()
    .filter((nft) => nft.liquidity > 0n)

  return Promise.all(
    nfts.map(async (nft): Promise<WalletLpPosition> => {
      const manager = managers.get(lower(nft.manager))!
      const positionKey = positionKeyOf(manager.generation, nft.tokenId)
      const candidates = bound.filter(
        ({ binding }) =>
          lower(binding.positionManager) === lower(nft.manager) &&
          lower(binding.token0) === nft.token0 &&
          lower(binding.token1) === nft.token1 &&
          binding.tickLower === nft.tickLower &&
          binding.tickUpper === nft.tickUpper,
      )
      let market: WalletLpPosition["market"] = null
      for (const { market: m, binding } of candidates) {
        const units = await (
          client.readContract({
            address: binding.lpVault,
            abi: LP_VAULT_ABI,
            functionName: "validatePosition",
            args: [BigInt(m.marketId), wallet, positionKey],
          }) as Promise<bigint>
        ).catch(() => 0n)
        if (units === 0n) continue
        market = {
          marketId: m.marketId,
          poolSlug: m.slug,
          integrationId: m.integrationId,
          lpVault: binding.lpVault,
          units,
          valueUsd6: (units * BigInt(m.acceptedPrice)) / pow10(m.vaultDecimals) / 100n,
        }
        break
      }
      const [symbol0, symbol1, pool] = await Promise.all([
        symbolOf(client, chainId, nft.token0),
        symbolOf(client, chainId, nft.token1),
        market ? Promise.resolve(null) : poolOf(client, chainId, nft),
      ])
      return {
        chainId,
        venue: manager.venue,
        npm: nft.manager,
        tokenId: nft.tokenId,
        positionKey,
        token0: nft.token0,
        token1: nft.token1,
        pair: `${symbol0 ?? "?"} / ${symbol1 ?? "?"}`,
        pool,
        market,
      }
    }),
  )
}

/** Wallet-tab LP rows: one per market for the NFTs it accepts, and one per unsupported NFT. */
function lpRows(
  wallet: Address,
  positions: readonly WalletLpPosition[],
  markets: readonly BalanceMarket[],
): UserAssetBalance[] {
  const walletId = lower(wallet)
  const rows: UserAssetBalance[] = []
  for (const market of markets) {
    const units = positions.reduce(
      (sum, p) => (p.market?.marketId === market.marketId ? sum + p.market.units : sum),
      0n,
    )
    if (units === 0n) continue
    const amount = Number(formatUnits(units, market.vaultDecimals))
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
  for (const p of positions) {
    if (p.market) continue
    const assetId = `lp:${p.chainId}:${lower(p.npm)}:${p.tokenId}`
    rows.push({
      id: `${walletId}:${assetId}:unsupported`,
      walletId,
      assetId,
      amount: 0,
      valueUsd: 0,
      symbol: p.pair,
      name: p.pair,
      isLpToken: true,
      sourceType: "borrow_collateral_unpledged",
      unsupportedLp: { chainId: p.chainId, venue: p.venue, pool: p.pool },
    })
  }
  return rows
}

/** The wallet's token and LP balances on one chain, and its LP NFTs; a read that fails leaves its rows out. */
export async function readChainWallet({
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
}): Promise<{ rows: UserAssetBalance[]; lpPositions: WalletLpPosition[] }> {
  const [liquid, lpPositions] = await Promise.all([
    tokenRows(client, chainId, wallet, tokens, assets),
    readWalletLpPositions({ client, chainId, wallet, markets }).catch(() => [] as WalletLpPosition[]),
  ])
  return { rows: [...liquid, ...lpRows(wallet, lpPositions, markets)], lpPositions }
}

/** The wallet's token and LP balance rows on one chain. */
export async function readChainWalletBalances(
  args: Parameters<typeof readChainWallet>[0],
): Promise<UserAssetBalance[]> {
  return (await readChainWallet(args)).rows
}
