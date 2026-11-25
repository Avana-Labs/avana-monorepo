// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Market scenarios of the local rehearsal, on the markets of the release manifest (deployments-local/<network>/
// manifest.json, from markets.json of script/deploy/09_ListMarkets.s.sol; two markets per pool, Full range and Custom
// range): an LP's whole life on a Uniswap v3, a Slipstream and a Uniswap v4 market through the integration's
// AaveAdapter (pledge, borrow, fees, repay with collateral through FlashloanRepay, repay, withdraw), LPOracle price
// paths on Aave's own prices, keeper liquidations through the LiquidationModule (on a Uniswap v4 market, of a borrower
// the USDC issuer has blocked), a self-liquidation attempt, a deficit covered by the First-Loss Reserve, and a debt
// reserve refused with another Hub's First-Loss Reserve. Each scenario uses its own wallet, starts from the world's
// configured feed prices and leaves them restored. Prices move only by signed OCR2 rounds on the primary feeds that
// Aave's oracle reads; pools move only by swaps through the world's routers (the UniswapV4PoolActor for Uniswap v4).

import {
  type Address,
  type Hex,
  type TransactionReceipt,
  encodeAbiParameters,
  encodeFunctionData,
  encodePacked,
  formatUnits,
  maxUint256,
  parseAbi,
  parseEventLogs,
  toHex,
} from "viem";
import {
  aaveAdapterAbi,
  aaveV4HubAbi,
  aaveV4SpokeAbi,
  accessManagerAbi,
  firstLossReserveAbi,
  flashloanRepayAbi,
  liquidationModuleAbi,
  lpOracleAbi,
  lpVaultAbi,
  riskModuleAbi,
  vaultTokenAbi,
} from "../../../../packages/protocol/src/abis/index.ts";
import { transmit } from "./ocr2.ts";
import type { Scenario, ScenarioContext, ScenarioRun } from "./context.ts";

// ─── Third-party interfaces (Uniswap v3 periphery 24ccf01, Slipstream 1.0.0, test tokens) ───

const ERC20 = parseAbi([
  "function mint(address to, uint256 amount)",
  "function MINTER() view returns (address)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function balanceOf(address account) view returns (uint256)",
  "function decimals() view returns (uint8)",
]);
const POOL = parseAbi([
  "function token0() view returns (address)",
  "function token1() view returns (address)",
  "function fee() view returns (uint24)",
  "function tickSpacing() view returns (int24)",
  "function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked)",
]);
const UNI_FACTORY = parseAbi(["function getPool(address tokenA, address tokenB, uint24 fee) view returns (address)"]);
const NFT = parseAbi([
  "function approve(address to, uint256 tokenId)",
  "function ownerOf(uint256 tokenId) view returns (address)",
  "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)",
]);
const UNI_NPM = parseAbi([
  "struct MintParams { address token0; address token1; uint24 fee; int24 tickLower; int24 tickUpper; uint256 amount0Desired; uint256 amount1Desired; uint256 amount0Min; uint256 amount1Min; address recipient; uint256 deadline; }",
  "function mint(MintParams params) payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)",
]);
const SLIP_NPM = parseAbi([
  "struct MintParams { address token0; address token1; int24 tickSpacing; int24 tickLower; int24 tickUpper; uint256 amount0Desired; uint256 amount1Desired; uint256 amount0Min; uint256 amount1Min; address recipient; uint256 deadline; uint160 sqrtPriceX96; }",
  "function mint(MintParams params) payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)",
]);
// Uniswap v4: the LPVault's registered pool key, the StateView's slot0, Permit2's allowance and the PositionManager batch.
const V4_VAULT = parseAbi([
  "struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }",
  "function poolKey(bytes32 poolId) view returns (PoolKey)",
]);
const V4_STATE_VIEW = parseAbi(["function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)"]);
const PERMIT2 = parseAbi(["function approve(address token, address spender, uint160 amount, uint48 expiration)"]);
const V4_POSM = parseAbi(["function modifyLiquidities(bytes unlockData, uint256 deadline) payable"]);
/** PositionManager actions (v4-periphery `Actions`) and `ActionConstants.MSG_SENDER`. */
const V4_MINT_POSITION = 0x02;
const V4_SETTLE_PAIR = 0x0d;
const V4_SWEEP = 0x14;
const V4_MSG_SENDER = "0x0000000000000000000000000000000000000001";
/** The world's Uniswap v4 swap helper (script/deploy/local/UniswapV4PoolActor.sol) and v4-core's price bounds. */
const V4_ACTOR = parseAbi([
  "struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }",
  "function swap(PoolKey key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) returns (int256 delta)",
]);
const MIN_SQRT_PRICE = 4295128739n;
const MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342n;
/** The local USDC's issuer blocklist (BlocklistToken, script/deploy/local/HostileTokens.sol). */
const BLOCKLIST = parseAbi(["function setBlocked(address account, bool blocked)", "function isBlocked(address account) view returns (bool)"]);
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const Q96 = 1n << 96n;
const UNI_ROUTER = parseAbi([
  "struct ExactInputSingleParams { address tokenIn; address tokenOut; uint24 fee; address recipient; uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96; }",
  "function exactInputSingle(ExactInputSingleParams params) payable returns (uint256 amountOut)",
]);
/** Byte offset of `amountIn` in an `exactInputSingle` call: the selector and five 32-byte words before it. */
const EXACT_INPUT_AMOUNT_OFFSET = 4n + 5n * 32n;
const HUB = parseAbi([
  "function getAssetId(address underlying) view returns (uint256)",
  "function getAssetLiquidity(uint256 assetId) view returns (uint256)",
]);
const LEND_SPOKE = parseAbi([
  "function getReserveId(address hub, uint256 assetId) view returns (uint256)",
  "function supply(uint256 reserveId, uint256 amount, address onBehalfOf) returns (uint256, uint256)",
]);

/** Every Avana and Aave V4 error, so a revert is decoded by name whichever contract raised it. */
const ERRORS = [
  ...aaveAdapterAbi,
  ...liquidationModuleAbi,
  ...flashloanRepayAbi,
  ...vaultTokenAbi,
  ...lpVaultAbi,
  ...lpOracleAbi,
  ...riskModuleAbi,
  ...firstLossReserveAbi,
  ...accessManagerAbi,
  ...aaveV4SpokeAbi,
  ...aaveV4HubAbi,
].filter((i: any) => i.type === "error") as readonly unknown[];
export const withErrors = (abi: readonly unknown[]) => [...abi, ...ERRORS] as readonly unknown[];

// ─── Constants ───

export const WAD = 10n ** 18n;
const RAY = 10n ** 27n;
const ONE_USD = 100_000_000n;
/** A feed's heartbeat (86,400 s) and its margin (1,800 s): past this the old LPOracle refused a price; this one does not. */
const STALE_AFTER = 88_200;
/** The symbols the listed markets and their debt reserves read. */
const MARKET_SYMBOLS = ["USDC", "USDT", "WETH", "wstETH", "GHO"] as const;
/** The AccessManager's governance role (AvanaRoles.GOVERNANCE_ROLE) and the longest governance delay plus a second. */
const GOVERNANCE_ROLE = 2n;
const GOVERNANCE_WAIT = 5 * 86_400 + 1;

// Scenario wallets, one per scenario (two for the keeper scenario).
const WALLETS = {
  uniswapLp: "0x1000000000000000000000000000000000000c01",
  slipstreamLp: "0x1000000000000000000000000000000000000c02",
  uniswapBorrower: "0x1000000000000000000000000000000000000c04",
  slipstreamBorrower: "0x1000000000000000000000000000000000000c44",
  selfLiquidator: "0x1000000000000000000000000000000000000c05",
  deficitBorrower: "0x1000000000000000000000000000000000000c06",
  swapper: "0x1000000000000000000000000000000000000c0a",
  lender: "0x1000000000000000000000000000000000000c0b",
  uniswapV4Lp: "0x1000000000000000000000000000000000000c21",
  uniswapV4Borrower: "0x1000000000000000000000000000000000000c22",
} as const satisfies Record<string, Address>;

// ─── Concentrated-liquidity math ───

/** √(1.0001^tick) in Q64.96, in floating point (relative error near 1e-15; callers keep a margin). */
function sqrtAtTick(tick: number): bigint {
  return BigInt(Math.floor(Math.sqrt(Math.pow(1.0001, tick)) * 2 ** 96));
}

/** The most liquidity `a0` and `a1` buy on [lower, upper] at `sqrtP` (Q64.96), as `LiquidityAmounts` computes it. */
export function v4Liquidity(sqrtP: bigint, lower: number, upper: number, a0: bigint, a1: bigint): bigint {
  const sa = sqrtAtTick(lower);
  const sb = sqrtAtTick(upper);
  const for0 = (lo: bigint) => (a0 * ((lo * sb) / Q96)) / (sb - lo);
  const for1 = (hi: bigint) => (a1 * Q96) / (hi - sa);
  if (sqrtP <= sa) return for0(sa);
  if (sqrtP >= sb) return for1(sb);
  const l0 = for0(sqrtP);
  const l1 = for1(sqrtP);
  return l0 < l1 ? l0 : l1;
}

// ─── Types ───

export type MarketKind = "full-range" | "custom-range";

/** One market of the release manifest, with its integration's core stack and its Spoke's debt reserve. */
export interface Market {
  /** The pool's listing name, shared by its two markets. */
  readonly name: string;
  readonly kind: MarketKind;
  /** Market IDs are per RiskModule: `integrationId:marketId` names a market on the chain. */
  readonly key: string;
  readonly marketId: bigint;
  readonly integrationId: number;
  /** "uniswap-v3", "slipstream" or "uniswap-v4". */
  readonly integrationKind: string;
  readonly spokeLabel: string;
  readonly spoke: Address;
  readonly hub: Address;
  /** The pool contract; the zero address for a Uniswap v4 market. */
  readonly pool: Address;
  /** The bytes32 pool key: a pool address left-padded, or a Uniswap v4 PoolId. */
  readonly poolId: Hex;
  readonly token0: Address;
  readonly token1: Address;
  readonly bandLower: number;
  readonly bandUpper: number;
  readonly unitDecimals: number;
  readonly ltvBps: bigint;
  readonly vaultToken: Address;
  readonly lpOracle: Address;
  /** The vault token's reserve on the Spoke. */
  readonly reserveId: bigint;
  /** The debt reserve this scenario borrows (GHO, else USDC, else the Spoke's first); -1 when the Spoke has none. */
  readonly debtAsset: Address;
  readonly debtReserveId: bigint;
  readonly lpVault: Address;
  readonly riskModule: Address;
  readonly adapter: Address;
  readonly liquidationModule: Address;
  readonly flashloanRepay: Address;
}

export interface Position {
  readonly tokenId: bigint;
  /** The LPVault's position key: bytes32(tokenId), or (generation << 248) | tokenId for Slipstream. */
  readonly key: Hex;
  readonly npm: Address;
  readonly liquidity: bigint;
  readonly amounts: readonly [bigint, bigint];
}

export interface Account {
  /** The wallet's account proxy in the market: the Aave user. */
  readonly proxy: Address;
  readonly marketId: bigint;
  readonly credit: bigint;
  readonly collateralReserveId: bigint;
  readonly debtReserveId: bigint;
}

/** Raised by a step whose failure ends the scenario; `run` turns it into a fail with the numbers so far. */
export class StepError extends Error {}

// ─── Small helpers ───

const eq = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
export const pct = (x: bigint, bps: bigint) => (x * bps) / 10_000n;
export const fmt = (x: bigint, decimals: number) => formatUnits(x, decimals);
export const usd8 = (x: bigint) => `$${formatUnits(x, 8)}`;

/** The first revert reason viem decoded along an error's cause chain, else its first line. */
export function errorName(e: unknown): string {
  let cur: any = e;
  for (let i = 0; cur && i < 8; i++) {
    if (cur.data?.errorName) {
      const args = (cur.data.args ?? []).map((a: unknown) => String(a)).join(", ");
      return `${cur.data.errorName}(${args})`;
    }
    if (typeof cur.signature === "string" && cur.signature.startsWith("0x")) return `undecoded error ${cur.signature}`;
    cur = cur.cause;
  }
  return (e as Error).message.split("\n")[0] ?? String(e);
}

// ─── The scenario environment ───

export class Env {
  readonly ctx: ScenarioContext;
  readonly numbers: Record<string, string> = {};
  readonly accessManager: Address;
  readonly markets: Market[];
  readonly prices: Record<string, bigint>;
  readonly decimalsOf: Record<string, number>;
  readonly symbolOf: Record<string, string>;
  private readonly minters: Record<string, Address> = {};

  constructor(ctx: ScenarioContext) {
    this.ctx = ctx;
    this.accessManager = ctx.manifest.avana.accessManager.address;
    this.prices = {};
    this.decimalsOf = {};
    for (const t of ctx.config.world.tokens as { symbol: string; decimals: number; price8: number | string }[]) {
      this.prices[t.symbol] = BigInt(t.price8);
      this.decimalsOf[t.symbol] = t.decimals;
    }
    this.symbolOf = {};
    for (const [sym, addr] of Object.entries(ctx.world.tokens ?? {})) this.symbolOf[(addr as string).toLowerCase()] = sym;
    const integrations = ctx.manifest.avana.integrations as any[];
    const debtReserves = (ctx.manifest.debtReserves ?? []) as any[];
    const spokeLabels = Object.entries((ctx.aave.spokes ?? {}) as Record<string, { proxy: string }>);
    this.markets = (ctx.manifest.markets as any[]).map((m) => {
      const x = integrations.find((i) => Number(i.integrationId) === Number(m.integrationId));
      if (!x) throw new StepError(`market ${m.name} names integration ${m.integrationId}, which the manifest does not list`);
      const debts = debtReserves.filter((r) => eq(r.spoke, m.spoke));
      const d = debts.find((r) => r.isGho) ?? debts.find((r) => this.symbolOf[String(r.asset).toLowerCase()] === "USDC") ?? debts[0];
      const v4 = x.kind === "uniswap-v4";
      return {
        name: m.name,
        kind: m.kind,
        key: `${m.integrationId}:${m.marketId}`,
        marketId: BigInt(m.marketId),
        integrationId: Number(m.integrationId),
        integrationKind: x.kind,
        spokeLabel: spokeLabels.find(([, s]) => eq(s.proxy, m.spoke))?.[0] ?? m.spoke,
        spoke: m.spoke,
        hub: m.hub,
        pool: (v4 ? ZERO_ADDRESS : `0x${String(m.pool).slice(-40)}`) as Address,
        poolId: m.pool as Hex,
        token0: m.tokens[0],
        token1: m.tokens[1],
        bandLower: Number(m.bandLower),
        bandUpper: Number(m.bandUpper),
        unitDecimals: Number(m.unitDecimals),
        ltvBps: BigInt(m.ltvBps),
        vaultToken: m.vaultToken.address,
        lpOracle: m.lpOracle.address,
        reserveId: BigInt(m.reserveId),
        debtAsset: (d?.asset ?? ZERO_ADDRESS) as Address,
        debtReserveId: d ? BigInt(d.debtReserveId) : -1n,
        lpVault: x.lpVault.address,
        riskModule: x.riskModule.address,
        adapter: x.aaveAdapter.address,
        liquidationModule: x.liquidationModule.address,
        flashloanRepay: x.flashloanRepay.address,
      } satisfies Market;
    });
  }

  /** The market of pool `name` of `kind` (Full range by default: positions on the pool's whole usable range). */
  market(name: string, kind: MarketKind = "full-range"): Market {
    const m = this.markets.find((x) => x.name === name && x.kind === kind);
    if (!m) throw new StepError(`no ${kind} market ${name} in the manifest`);
    return m;
  }

  /** A market by its `integrationId:marketId` key. */
  marketByKey(key: string): Market {
    const m = this.markets.find((x) => x.key === key);
    if (!m) throw new StepError(`no market ${key} in the manifest`);
    return m;
  }

  token(sym: string): Address {
    const t = this.ctx.world.tokens?.[sym] as Address | undefined;
    if (!t) throw new StepError(`no ${sym} in world.json`);
    return t;
  }

  sym(token: Address): string {
    return this.symbolOf[token.toLowerCase()] ?? token;
  }

  dec(token: Address): number {
    const d = this.decimalsOf[this.sym(token)];
    if (d === undefined) throw new StepError(`no decimals for ${token}`);
    return d;
  }

  hubLabel(hub: Address): string {
    for (const [label, h] of Object.entries(this.ctx.aave.hubs ?? {})) if (eq((h as any).proxy, hub)) return label;
    throw new StepError(`hub ${hub} not in aave.json`);
  }

  isSlipstream(m: Market): boolean {
    return m.integrationKind === "slipstream";
  }

  isUniswapV3(m: Market): boolean {
    return m.integrationKind === "uniswap-v3";
  }

  isUniswapV4(m: Market): boolean {
    return m.integrationKind === "uniswap-v4";
  }

  /** The Slipstream generation of a market's pool (the listing config's `generation`, else 0). */
  generation(m: Market): number {
    const cfg = (this.ctx.config.listing.markets as { name: string; generation?: number }[]).find((x) => x.name === m.name);
    return cfg?.generation ?? 0;
  }

  read(address: Address, abi: readonly unknown[], fn: string, args: readonly unknown[] = []) {
    return this.ctx.read(address, abi, fn, args);
  }

  /** Sends and throws a StepError naming `step` on any failure. */
  async must(step: string, from: Address, to: Address, abi: readonly unknown[], fn: string, args: readonly unknown[], opts: { gas?: bigint; value?: bigint } = {}) {
    const r = await this.ctx.send(from, to, withErrors(abi), fn, args, opts);
    if (!r.ok) throw new StepError(`${step}: ${r.error}`);
    return r;
  }

  async rpc(method: string, params: unknown[] = []) {
    return this.ctx.client.request({ method: method as any, params: params as any });
  }

  async now(): Promise<bigint> {
    return (await this.ctx.client.getBlock()).timestamp;
  }

  async deadline(seconds = 3600n): Promise<bigint> {
    return (await this.now()) + seconds;
  }

  async advance(seconds: number) {
    await this.rpc("evm_increaseTime", [seconds]);
    await this.rpc("evm_mine", []);
  }

  async gasFor(...who: Address[]) {
    for (const a of who) await this.rpc("anvil_setBalance", [a, "0x3635C9ADC5DEA00000"]).catch(() => undefined);
  }

  async balance(token: Address, who: Address): Promise<bigint> {
    return (await this.read(token, ERC20, "balanceOf", [who])) as bigint;
  }

  /** Mints a test token (TestToken: only its MINTER, the world deployer, mints). */
  async mint(token: Address, to: Address, amount: bigint) {
    const k = token.toLowerCase();
    if (!this.minters[k]) {
      this.minters[k] = (await this.read(token, ERC20, "MINTER").catch(() => this.ctx.actors.deployer)) as Address;
      await this.gasFor(this.minters[k]!);
    }
    await this.must(`mint ${this.sym(token)}`, this.minters[k]!, token, ERC20, "mint", [to, amount]);
  }

  async approve(owner: Address, token: Address, spender: Address, amount: bigint) {
    await this.must(`approve ${this.sym(token)}`, owner, token, ERC20, "approve", [spender, amount]);
  }

  /** Raw amount of `token` worth `usd` whole dollars at the configured price. */
  amountForUsd(token: Address, usd: bigint): bigint {
    const sym = this.sym(token);
    const p = this.prices[sym];
    if (p === undefined) throw new StepError(`no price for ${sym}`);
    return (usd * ONE_USD * 10n ** BigInt(this.dec(token))) / p;
  }

  // ─── Prices and oracles ───

  /**
   * Moves each token of `symbols` (all of `prices` by default) to `prices[symbol]`, else keeps its configured price,
   * with one OCR2 round on its primary feed: the price source of its reserve on the price Spoke, which Aave V4's
   * AaveOracle reads with no age limit and every LPOracle reads through it (02_DeployWorld lists every world token there
   * on its primary feed).
   */
  async refresh(prices: Record<string, bigint>, symbols?: readonly string[]) {
    const feeds = (this.ctx.world.feeds ?? {}) as Record<string, Record<string, Address>>;
    for (const sym of symbols ?? Object.keys(prices)) {
      const aggregator = feeds[sym]?.primaryAggregator;
      if (!aggregator) throw new StepError(`no primary feed aggregator for ${sym} in world.json`);
      const answer = prices[sym] ?? this.prices[sym];
      if (answer === undefined) throw new StepError(`no price for ${sym}`);
      const hash = await transmit(this.ctx.client, this.ctx.wallet, aggregator, answer);
      const r = await this.ctx.client.waitForTransactionReceipt({ hash });
      if (r.status !== "success") throw new StepError(`transmit on ${sym}'s primary feed reverted`);
    }
  }

  /** The market LPOracle's answer, 8 decimals; the oracle is stateless, so every read at this block sees it. */
  async lpPrice(m: Market): Promise<bigint> {
    return BigInt(await this.read(m.lpOracle, lpOracleAbi, "latestAnswer"));
  }

  /**
   * Restores the configured prices (one fresh round per feed of `symbols`, all world symbols when `all`). The oracles
   * are stateless, so every listed market reads the restored prices at once; returns the count of markets priced.
   */
  async settle(all = false): Promise<string> {
    const symbols = (all ? Object.keys(this.prices) : [...MARKET_SYMBOLS]).filter((s) => this.ctx.world.feeds?.[s]?.primaryAggregator);
    const prices: Record<string, bigint> = {};
    for (const s of symbols) if (this.prices[s] !== undefined) prices[s] = this.prices[s]!;
    await this.refresh(prices, symbols);
    let priced = 0;
    const refused: string[] = [];
    for (const m of this.markets) {
      const ok = await this.lpPrice(m).then(() => true, () => false);
      if (ok) priced++;
      else refused.push(`${m.name} (${m.kind})`);
    }
    return `${symbols.length} feeds restored; ${priced}/${this.markets.length} LPOracles answer${refused.length ? `; no answer: ${refused.join(", ")}` : ""}`;
  }

  /** Moves a Uniswap v3 pool to `target` (sqrtPriceX96) by one exact-input swap with that price limit. */
  async moveUniswapPool(pool: Address, target: bigint): Promise<string> {
    const [t0, t1, fee] = await Promise.all([this.read(pool, POOL, "token0"), this.read(pool, POOL, "token1"), this.read(pool, POOL, "fee")]);
    const cur = (await this.read(pool, POOL, "slot0"))[0] as bigint;
    if (cur === target) return "already there";
    const zeroForOne = target < cur;
    const tokenIn = (zeroForOne ? t0 : t1) as Address;
    const tokenOut = (zeroForOne ? t1 : t0) as Address;
    // Ten times the pool's balance of the input token moves a full-range pool by more than 100x in price; the router
    // pulls only what the swap uses up to the limit.
    const amountIn = (await this.balance(tokenIn, pool)) * 10n + 10n ** BigInt(this.dec(tokenIn));
    const router = this.ctx.world.uniswapV3SwapRouter as Address;
    await this.gasFor(WALLETS.swapper);
    await this.mint(tokenIn, WALLETS.swapper, amountIn);
    await this.approve(WALLETS.swapper, tokenIn, router, amountIn);
    await this.must("move pool", WALLETS.swapper, router, UNI_ROUTER, "exactInputSingle", [
      { tokenIn, tokenOut, fee, recipient: WALLETS.swapper, deadline: await this.deadline(), amountIn, amountOutMinimum: 0n, sqrtPriceLimitX96: target },
    ]);
    const after = (await this.read(pool, POOL, "slot0")) as readonly [bigint, number];
    return `sqrtPriceX96 ${cur} -> ${after[0]} (tick ${after[1]})`;
  }

  // ─── Positions and accounts ───

  /**
   * Mints a position on the market's band (the pool's usable range for a Full range market, the Custom range band
   * otherwise), worth about `usdEach` of each token, and approves the LPVault for the NFT.
   */
  async mintPosition(m: Market, owner: Address, usdEach: bigint): Promise<Position> {
    if (this.isUniswapV4(m)) return this.mintV4Position(m, owner, usdEach);
    const a0 = this.amountForUsd(m.token0, usdEach);
    const a1 = this.amountForUsd(m.token1, usdEach);
    const slip = this.isSlipstream(m);
    const gen = this.generation(m);
    const npm = (slip ? this.ctx.world.slipstreamPositionManagers?.[gen] : this.ctx.world.uniswapV3PositionManager) as Address;
    if (!npm) throw new StepError(`no position manager for ${m.name}`);
    await this.gasFor(owner);
    await this.mint(m.token0, owner, a0);
    await this.mint(m.token1, owner, a1);
    await this.approve(owner, m.token0, npm, a0);
    await this.approve(owner, m.token1, npm, a1);
    const base = {
      token0: m.token0,
      token1: m.token1,
      tickLower: m.bandLower,
      tickUpper: m.bandUpper,
      amount0Desired: a0,
      amount1Desired: a1,
      amount0Min: 0n,
      amount1Min: 0n,
      recipient: owner,
      deadline: await this.deadline(),
    };
    const r = slip
      ? await this.must("Slipstream mint", owner, npm, SLIP_NPM, "mint", [{ ...base, tickSpacing: Number(await this.read(m.pool, POOL, "tickSpacing")), sqrtPriceX96: 0n }])
      : await this.must("Uniswap mint", owner, npm, UNI_NPM, "mint", [{ ...base, fee: Number(await this.read(m.pool, POOL, "fee")) }]);
    const used = r.result as readonly bigint[];
    const tokenId = this.mintedTokenId(r.receipt!, npm, owner) ?? used[0]!;
    // The LPVault's key: bytes32(tokenId) for Uniswap v3, bytes32((generation << 248) | tokenId) for Slipstream.
    const key = toHex(slip ? (BigInt(gen) << 248n) | tokenId : tokenId, { size: 32 });
    await this.must("approve the LPVault", owner, npm, NFT, "approve", [m.lpVault, tokenId]);
    return { tokenId, key, npm, liquidity: used[1]!, amounts: [used[2]!, used[3]!] };
  }

  /** The Uniswap v4 pool key the market's LPVault registered for its PoolId. */
  async v4Key(m: Market) {
    return (await this.read(m.lpVault, V4_VAULT, "poolKey", [m.poolId])) as { currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address };
  }

  /**
   * Uniswap v4: mints through the PositionManager (MINT_POSITION, SETTLE_PAIR, and SWEEP of the ether left for a native
   * pool), paid through Permit2 or by value for native ETH, and approves the LPVault. The liquidity is the most both
   * amounts buy at the pool's price, less 1 % for the floating-point tick prices, so the maxima are never exceeded.
   */
  async mintV4Position(m: Market, owner: Address, usdEach: bigint): Promise<Position> {
    const posm = this.ctx.world.uniswapV4PositionManager as Address;
    const permit2 = this.ctx.world.permit2 as Address;
    const stateView = this.ctx.world.uniswapV4StateView as Address;
    if (!posm || !permit2 || !stateView) throw new StepError(`no Uniswap v4 world for ${m.name}`);
    const key = await this.v4Key(m);
    const native = eq(key.currency0, ZERO_ADDRESS);
    const a0 = this.amountForUsd(m.token0, usdEach);
    const a1 = this.amountForUsd(m.token1, usdEach);
    await this.gasFor(owner);
    if (native) await this.rpc("anvil_setBalance", [owner, toHex(a0 + 1_000n * 10n ** 18n)]);
    const expiry = (await this.now()) + 86_400n;
    for (const [c, a] of [
      [key.currency0, a0],
      [key.currency1, a1],
    ] as const) {
      if (eq(c, ZERO_ADDRESS)) continue;
      await this.mint(c, owner, a);
      await this.approve(owner, c, permit2, a);
      await this.must(`Permit2 approve ${this.sym(c)}`, owner, permit2, PERMIT2, "approve", [c, posm, a, Number(expiry)]);
    }
    const [sqrtP] = (await this.read(stateView, V4_STATE_VIEW, "getSlot0", [m.poolId])) as readonly [bigint, number];
    const liquidity = (v4Liquidity(sqrtP, m.bandLower, m.bandUpper, a0, a1) * 99n) / 100n;
    if (liquidity === 0n) throw new StepError(`${m.name}: no liquidity for ${usdEach} USD of each token`);
    const mintParams = encodeAbiParameters(
      [
        { type: "tuple", components: [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }] },
        { type: "int24" },
        { type: "int24" },
        { type: "uint256" },
        { type: "uint128" },
        { type: "uint128" },
        { type: "address" },
        { type: "bytes" },
      ],
      [[key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks], m.bandLower, m.bandUpper, liquidity, a0, a1, owner, "0x"],
    );
    const pair = encodeAbiParameters([{ type: "address" }, { type: "address" }], [key.currency0, key.currency1]);
    const actions: number[] = [V4_MINT_POSITION, V4_SETTLE_PAIR];
    const params: Hex[] = [mintParams, pair];
    if (native) {
      actions.push(V4_SWEEP);
      params.push(encodeAbiParameters([{ type: "address" }, { type: "address" }], [ZERO_ADDRESS, V4_MSG_SENDER]));
    }
    const unlockData = encodeAbiParameters([{ type: "bytes" }, { type: "bytes[]" }], [encodePacked(actions.map(() => "uint8"), actions), params]);
    const held = () => Promise.all([native ? this.ctx.client.getBalance({ address: owner }) : this.balance(key.currency0, owner), this.balance(key.currency1, owner)]);
    const before = await held();
    const r = await this.must("Uniswap v4 mint", owner, posm, V4_POSM, "modifyLiquidities", [unlockData, await this.deadline()], { value: native ? a0 : undefined });
    const tokenId = this.mintedTokenId(r.receipt!, posm, owner);
    if (tokenId === undefined) throw new StepError(`${m.name}: no PositionManager Transfer to ${owner}`);
    const after = await held();
    const gasPaid = native ? r.receipt!.gasUsed * r.receipt!.effectiveGasPrice : 0n;
    const used: [bigint, bigint] = [before[0] - after[0] - gasPaid, before[1] - after[1]];
    // The LPVault's key: bytes32(tokenId), as for Uniswap v3.
    const k = toHex(tokenId, { size: 32 });
    await this.must("approve the LPVault", owner, posm, NFT, "approve", [m.lpVault, tokenId]);
    return { tokenId, key: k, npm: posm, liquidity, amounts: used };
  }

  /**
   * Uniswap v4: an exact-input swap of `amountIn` on the market's pool through the world's UniswapV4PoolActor, which
   * pays from its own balance (funded here: the input token minted to it, or ether for the native currency) and keeps
   * the output. Returns the pool's price after the swap.
   */
  async swapV4(m: Market, zeroForOne: boolean, amountIn: bigint): Promise<string> {
    const actor = this.ctx.world.uniswapV4PoolActor as Address;
    const stateView = this.ctx.world.uniswapV4StateView as Address;
    if (!actor || !stateView) throw new StepError(`no Uniswap v4 pool actor for ${m.name}`);
    const key = await this.v4Key(m);
    const tokenIn = zeroForOne ? key.currency0 : key.currency1;
    if (eq(tokenIn, ZERO_ADDRESS)) {
      const held = await this.ctx.client.getBalance({ address: actor });
      await this.rpc("anvil_setBalance", [actor, toHex(held + amountIn)]);
    } else {
      await this.mint(tokenIn, actor, amountIn);
    }
    await this.gasFor(WALLETS.swapper);
    await this.must("Uniswap v4 swap", WALLETS.swapper, actor, V4_ACTOR, "swap", [key, zeroForOne, -amountIn, zeroForOne ? MIN_SQRT_PRICE + 1n : MAX_SQRT_PRICE - 1n]);
    const [sqrtP, tick] = (await this.read(stateView, V4_STATE_VIEW, "getSlot0", [m.poolId])) as readonly [bigint, number];
    return `${zeroForOne ? "0->1" : "1->0"} ${amountIn}: sqrtPriceX96 ${sqrtP} (tick ${tick})`;
  }

  /** Alternating exact-input swaps of about `usd` on a Uniswap v3 market's pool through the world's SwapRouter. */
  async swapUniswapV3(m: Market, usd: bigint, rounds: number) {
    const router = this.ctx.world.uniswapV3SwapRouter as Address;
    const fee = Number(await this.read(m.pool, POOL, "fee"));
    const s = WALLETS.swapper;
    await this.gasFor(s);
    const leg0 = this.amountForUsd(m.token0, usd);
    const leg1 = this.amountForUsd(m.token1, usd);
    await this.mint(m.token0, s, leg0 * BigInt(rounds));
    await this.mint(m.token1, s, leg1 * BigInt(rounds));
    await this.approve(s, m.token0, router, leg0 * BigInt(rounds));
    await this.approve(s, m.token1, router, leg1 * BigInt(rounds));
    for (let i = 0; i < rounds; i++) {
      const zeroForOne = i % 2 === 0;
      await this.must("fee swap", s, router, UNI_ROUTER, "exactInputSingle", [
        {
          tokenIn: zeroForOne ? m.token0 : m.token1,
          tokenOut: zeroForOne ? m.token1 : m.token0,
          fee,
          recipient: s,
          deadline: await this.deadline(),
          amountIn: zeroForOne ? leg0 : leg1,
          amountOutMinimum: 0n,
          sqrtPriceLimitX96: 0n,
        },
      ]);
    }
  }

  mintedTokenId(receipt: TransactionReceipt, npm: Address, owner: Address): bigint | undefined {
    const logs = parseEventLogs({ abi: NFT, logs: receipt.logs, eventName: "Transfer" });
    const l = logs.find((x) => eq(x.address, npm) && /^0x0+$/.test(x.args.from) && eq(x.args.to, owner));
    return l?.args.tokenId;
  }

  /** Supplies the debt asset on the Hub's Lend Spoke when the Hub holds less than `need`. */
  async ensureLiquidity(m: Market, need: bigint, asset: Address = m.debtAsset): Promise<string> {
    const assetId = (await this.read(m.hub, HUB, "getAssetId", [asset])) as bigint;
    const liquidity = (await this.read(m.hub, HUB, "getAssetLiquidity", [assetId])) as bigint;
    if (liquidity >= need) return fmt(liquidity, this.dec(asset));
    const label = this.hubLabel(m.hub);
    const lendLabel = (this.ctx.config.aavePayload.hubs as { label: string; lendSpoke: string }[]).find((h) => h.label === label)?.lendSpoke;
    const lend = lendLabel ? (this.ctx.aave.spokes?.[lendLabel]?.proxy as Address | undefined) : undefined;
    if (!lend) throw new StepError(`no Lend Spoke for Hub ${label}`);
    const reserveId = (await this.read(lend, LEND_SPOKE, "getReserveId", [m.hub, assetId])) as bigint;
    const amount = need * 2n;
    await this.gasFor(WALLETS.lender);
    await this.mint(asset, WALLETS.lender, amount);
    await this.approve(WALLETS.lender, asset, lend, amount);
    await this.must("Lend Spoke supply", WALLETS.lender, lend, LEND_SPOKE, "supply", [reserveId, amount, WALLETS.lender]);
    return `${fmt(liquidity, this.dec(asset))} + ${fmt(amount, this.dec(asset))} supplied`;
  }

  /** Pledges through the AaveAdapter, which routes the position to the market it fits: it must be `m`. */
  async pledge(m: Market, owner: Address, p: Position): Promise<Account> {
    if (m.debtReserveId < 0n) throw new StepError(`no debt reserve on ${m.spokeLabel} in the manifest`);
    const r = await this.must("pledge", owner, m.adapter, aaveAdapterAbi, "pledge", [p.key]);
    const [marketId, credit] = r.result as readonly [bigint, bigint];
    if (marketId !== m.marketId) throw new StepError(`pledge routed ${m.name} (${m.kind}) to market ${marketId}, not ${m.marketId}`);
    const proxy = (await this.read(m.adapter, aaveAdapterAbi, "accountOf", [owner, marketId])) as Address;
    return { proxy, marketId, credit, collateralReserveId: m.reserveId, debtReserveId: m.debtReserveId };
  }

  async borrow(m: Market, owner: Address, a: Account, amount: bigint) {
    return this.must("borrow", owner, m.adapter, aaveAdapterAbi, "borrow", [m.marketId, a.debtReserveId, amount, owner]);
  }

  /** `payer` repays up to `amount` of `wallet`'s debt (maxUint256: all of it; the adapter pulls only what is owed). */
  async repay(m: Market, payer: Address, wallet: Address, a: Pick<Account, "debtReserveId">, amount: bigint, fund: bigint): Promise<bigint> {
    await this.mint(m.debtAsset, payer, fund);
    await this.approve(payer, m.debtAsset, m.adapter, fund);
    const r = await this.must("repay", payer, m.adapter, aaveAdapterAbi, "repay", [m.marketId, a.debtReserveId, amount, wallet]);
    return r.result as bigint;
  }

  /** The largest borrow of a fresh account: 95 % of its collateral value times the market's LTV, at the debt asset's price. */
  async maxBorrow(m: Market, _owner: Address, a: Account): Promise<bigint> {
    const coll = await this.collateralUsd8(m, a);
    const price = this.prices[this.sym(m.debtAsset)] ?? ONE_USD;
    return (pct(pct(coll, m.ltvBps), 9_500n) * 10n ** BigInt(this.dec(m.debtAsset))) / price;
  }

  async debt(m: Market, a: Pick<Account, "proxy"> & Partial<Pick<Account, "debtReserveId">>): Promise<bigint> {
    return (await this.read(m.spoke, aaveV4SpokeAbi, "getUserTotalDebt", [a.debtReserveId ?? m.debtReserveId, a.proxy])) as bigint;
  }

  /** Vault-token units the account supplies on the Spoke. */
  async supplied(m: Market, a: Account): Promise<bigint> {
    return (await this.read(m.spoke, aaveV4SpokeAbi, "getUserSuppliedAssets", [a.collateralReserveId, a.proxy])) as bigint;
  }

  async healthFactor(m: Market, a: Account): Promise<bigint> {
    return (await this.read(m.spoke, aaveV4SpokeAbi, "getUserAccountData", [a.proxy])).healthFactor as bigint;
  }

  /** Supplied vault-token units valued at the LPOracle's answer, 8 decimals. */
  async collateralUsd8(m: Market, a: Account): Promise<bigint> {
    return ((await this.supplied(m, a)) * (await this.lpPrice(m))) / 10n ** BigInt(m.unitDecimals);
  }

  /** The LPVault's record of a position: owner account, market, liquidity and credit. */
  async record(m: Market, key: Hex): Promise<{ account: Address; marketId: bigint; liquidity: bigint; credit: bigint }> {
    const r = await this.read(m.lpVault, lpVaultAbi, "getPosition", [key]);
    if (/^0x0+$/.test(r.account)) throw new StepError(`no record ${key}`);
    return r;
  }

  /** The market's max liquidation bonus on its Spoke (bps, 10,000 = none), from the vault token reserve's config. */
  async maxLiquidationBonus(m: Market): Promise<bigint> {
    const r = await this.read(m.spoke, aaveV4SpokeAbi, "getReserve", [m.reserveId]);
    const d = await this.read(m.spoke, aaveV4SpokeAbi, "getDynamicReserveConfig", [m.reserveId, r.dynamicConfigKey]);
    return BigInt(d.maxLiquidationBonus);
  }

  /** The decoded revert of a call simulated as `from`, or `{ reverted: false }`. */
  async tryCall(from: Address, to: Address, abi: readonly unknown[], fn: string, args: readonly unknown[]) {
    try {
      const r = await this.ctx.client.simulateContract({ account: from, address: to, abi: withErrors(abi) as any, functionName: fn, args: args as any });
      return { reverted: false, name: "", result: r.result as any };
    } catch (e) {
      return { reverted: true, name: errorName(e), result: undefined as any };
    }
  }

  /**
   * A liquidation through the market's LiquidationModule: the liquidator is funded with the whole debt plus 1 % for
   * accrual, approves the module and calls `liquidate`; Aave takes what it sizes and the module refunds the rest, then
   * pays the unwound liquidity out in both pool tokens.
   */
  async liquidate(m: Market, a: Account, liquidator: Address, label: string) {
    const debtBefore = await this.debt(m, a);
    const debtToCover = debtBefore + debtBefore / 100n + 1n;
    await this.gasFor(liquidator);
    await this.mint(m.debtAsset, liquidator, debtToCover);
    await this.approve(liquidator, m.debtAsset, m.liquidationModule, debtToCover);
    const balBefore = await this.balance(m.debtAsset, liquidator);
    const params = { marketId: m.marketId, debtReserveId: a.debtReserveId, account: a.proxy, debtToCover, minAmount0: 0n, minAmount1: 0n, receiver: liquidator };
    const r = await this.ctx.send(liquidator, m.liquidationModule, withErrors(liquidationModuleAbi), "liquidate", [params]);
    const spent = balBefore - (await this.balance(m.debtAsset, liquidator));
    const debtAfter = await this.debt(m, a);
    const d = this.dec(m.debtAsset);
    const res = r.result ?? {};
    this.numbers[`${label}.liquidate`] = r.ok
      ? `debt ${fmt(debtBefore, d)} -> ${fmt(debtAfter, d)}; repaid ${fmt(res.debtRepaid, d)} (spent ${fmt(spent, d)}); seized ${res.seized} units (fee ${res.feeUnits}); credit unwound ${res.creditUnwound}; paid ${fmt(res.amount0, this.dec(m.token0))} ${this.sym(m.token0)} + ${fmt(res.amount1, this.dec(m.token1))} ${this.sym(m.token1)}; fee ${res.fee0}/${res.fee1} (gas ${r.gas})`
      : `reverted: ${r.error}`;
    return {
      ok: r.ok,
      debtBefore,
      debtAfter,
      spent,
      debtRepaid: r.ok ? (res.debtRepaid as bigint) : 0n,
      amount0: r.ok ? (res.amount0 as bigint) : 0n,
      amount1: r.ok ? (res.amount1 as bigint) : 0n,
      error: r.error,
    };
  }

  /** The crash ratio (bps of the WETH price) that leaves health factor `targetHf` from `hf` on a full-range market. */
  static crashBpsFor(hf: bigint, targetHf: bigint, capBps: bigint): bigint {
    // Full-range LP value moves with sqrt(price): HF' = HF × sqrt(r), so r = (targetHf / HF)^2.
    const r = (targetHf * targetHf * 10_000n) / (hf * hf);
    return r < capBps ? r : capBps;
  }

  /** WETH moved to `bps` of its configured price, USDC at its configured price; the stateless LPOracles read it at once. */
  async setWeth(bps: bigint) {
    await this.refresh({ WETH: pct(this.prices.WETH!, bps), USDC: this.prices.USDC! });
  }

  /**
   * Simulates an AccessManager-governed call as the governance Safe once its delay has passed: snapshot, `schedule` as
   * the Safe, the clock past the longest governance delay, `execute` simulated, and the snapshot reverted.
   */
  async governanceSimulate(target: Address, data: Hex) {
    const safe = this.ctx.actors.governanceSafe!;
    const snap = (await this.rpc("evm_snapshot", [])) as string;
    try {
      await this.gasFor(safe);
      await this.must("schedule as the governance Safe", safe, this.accessManager, accessManagerAbi, "schedule", [target, data, 0]);
      await this.advance(GOVERNANCE_WAIT);
      return await this.tryCall(safe, this.accessManager, accessManagerAbi, "execute", [target, data]);
    } finally {
      await this.rpc("evm_revert", [snap]);
    }
  }
}

/** Runs a scenario body; a StepError or any other throw becomes a fail with the numbers gathered so far. */
export async function runWith(ctx: ScenarioContext, body: (e: Env) => Promise<{ ok: boolean; detail: string }>): Promise<ScenarioRun> {
  let e: Env | undefined;
  try {
    e = new Env(ctx);
    const r = await body(e);
    return { ...r, numbers: e.numbers };
  } catch (err) {
    const detail = err instanceof StepError ? err.message : ((err as Error).message.split("\n")[0] ?? String(err));
    return { ok: false, detail, ...(e ? { numbers: e.numbers } : {}) };
  }
}

// ─── Shared steps ───

/** Fees through `AaveAdapter.collectFees`: what it pays must be what `LPVault.feesOf` showed. */
async function collect(e: Env, m: Market, lp: Address, p: Position) {
  const [owed0, owed1] = (await e.read(m.lpVault, lpVaultAbi, "feesOf", [p.key])) as readonly [bigint, bigint];
  const b0 = await e.balance(m.token0, lp);
  const b1 = await e.balance(m.token1, lp);
  const c = await e.must("collectFees", lp, m.adapter, aaveAdapterAbi, "collectFees", [m.marketId, [p.key]]);
  const f0 = (await e.balance(m.token0, lp)) - b0;
  const f1 = (await e.balance(m.token1, lp)) - b1;
  const [r0, r1] = c.result as readonly [readonly bigint[], readonly bigint[]];
  e.numbers.fees = `feesOf ${owed0}/${owed1}; collected ${fmt(f0, e.dec(m.token0))} ${e.sym(m.token0)} + ${fmt(f1, e.dec(m.token1))} ${e.sym(m.token1)} (returned ${r0[0]}/${r1[0]})`;
  return { f0, f1, matches: f0 === r0[0] && f1 === r1[0] && f0 >= owed0 && f1 >= owed1 };
}

/** The debt repaid in full by the LP, then the whole NFT withdrawn back to it. */
async function repayAllAndWithdraw(e: Env, m: Market, lp: Address, a: Account, p: Position) {
  const d = e.dec(m.debtAsset);
  const rest = await e.debt(m, a);
  const repaid = await e.repay(m, lp, lp, a, maxUint256, rest + rest / 100n + 10n ** BigInt(d));
  const debt = await e.debt(m, a);
  e.numbers.repay = `repaid ${fmt(repaid, d)} of ${fmt(rest, d)}; debt now ${fmt(debt, d)}`;
  await e.must("withdraw", lp, m.adapter, aaveAdapterAbi, "withdraw", [p.key, 0n, 0n, 0n, lp]);
  const owner = (await e.read(p.npm, NFT, "ownerOf", [p.tokenId])) as Address;
  const left = await e.supplied(m, a);
  e.numbers.withdraw = `NFT owner ${owner}; supplied units left ${left}`;
  return debt === 0n && eq(owner, lp) && left === 0n;
}

/** A pool of the world's Uniswap v3 factory between `a` and `b`, the first of the standard fee tiers. */
async function uniswapV3PoolOf(e: Env, a: Address, b: Address): Promise<{ pool: Address; fee: number }> {
  const factory = e.ctx.world.uniswapV3Factory as Address;
  for (const fee of [100, 500, 3000, 10_000]) {
    const pool = (await e.read(factory, UNI_FACTORY, "getPool", [a, b, fee])) as Address;
    if (!eq(pool, ZERO_ADDRESS)) return { pool, fee };
  }
  throw new StepError(`no Uniswap v3 pool of ${e.sym(a)}/${e.sym(b)}`);
}

// ─── 1. Uniswap v3 LP: pledge, borrow GHO, fees, repay with collateral, repay, withdraw ───

async function uniswapLifecycle(e: Env) {
  const m = e.market("uni-USDC-USDT-100");
  const lp = WALLETS.uniswapLp;
  const n = e.numbers;
  n.settle = await e.settle();
  const p = await e.mintPosition(m, lp, 50_000n);
  n.position = `tokenId ${p.tokenId} key ${p.key}; minted ${fmt(p.amounts[0], e.dec(m.token0))} ${e.sym(m.token0)} + ${fmt(p.amounts[1], e.dec(m.token1))} ${e.sym(m.token1)} on [${m.bandLower}, ${m.bandUpper}]`;
  const a = await e.pledge(m, lp, p);
  n.pledge = `market ${m.key} (${m.kind}); account ${a.proxy}; credit ${a.credit}; collateral ${usd8(await e.collateralUsd8(m, a))}`;
  const d = e.dec(m.debtAsset);
  const amount = 20_000n * 10n ** BigInt(d);
  n.liquidity = await e.ensureLiquidity(m, amount);
  const before = await e.balance(m.debtAsset, lp);
  await e.borrow(m, lp, a, amount);
  const got = (await e.balance(m.debtAsset, lp)) - before;
  const debt1 = await e.debt(m, a);
  n.borrow = `${fmt(amount, d)} ${e.sym(m.debtAsset)}; wallet +${fmt(got, d)}; debt ${fmt(debt1, d)}; HF ${fmt(await e.healthFactor(m, a), 18)}`;
  if (got !== amount || debt1 < amount) return { ok: false, detail: "borrow did not move the wallet and the debt by the amount" };

  // Fees: alternating swaps through the world's SwapRouter on the market's pool.
  await e.swapUniswapV3(m, 20_000n, 6);
  const fees = await collect(e, m, lp, p);
  if (fees.f0 + fees.f1 === 0n || !fees.matches) return { ok: false, detail: "collectFees paid nothing, or not what it returned and feesOf showed" };

  // Repay a quarter of the debt with a fifth of the position through FlashloanRepay: the wallet lets it withdraw that
  // liquidity for one call; it flash-borrows the debt asset from the Aave V3 Pool, repays, withdraws, swaps both pool
  // tokens to the debt asset on the world's Uniswap v3 pools, repays the loan and sends the rest to the wallet.
  const rec = await e.record(m, p.key);
  const liquidity = rec.liquidity / 5n;
  const repayAmount = debt1 / 4n;
  const router = e.ctx.world.uniswapV3SwapRouter as Address;
  const swaps = [];
  for (const t of [m.token0, m.token1]) {
    const { fee } = await uniswapV3PoolOf(e, t, m.debtAsset);
    swaps.push({
      tokenIn: t,
      target: router,
      data: encodeFunctionData({
        abi: UNI_ROUTER,
        functionName: "exactInputSingle",
        args: [{ tokenIn: t, tokenOut: m.debtAsset, fee, recipient: m.flashloanRepay, deadline: await e.deadline(), amountIn: 0n, amountOutMinimum: 0n, sqrtPriceLimitX96: 0n }],
      }),
      amountInOffset: EXACT_INPUT_AMOUNT_OFFSET,
    });
  }
  const mins = p.amounts.map((x) => pct((x * liquidity) / p.liquidity, 9_000n));
  const data = encodeAbiParameters(
    [
      {
        type: "tuple",
        components: [
          { name: "reserveId", type: "uint256" },
          { name: "amount", type: "uint256" },
          { name: "liquidity", type: "uint128" },
          { name: "amount0Min", type: "uint256" },
          { name: "amount1Min", type: "uint256" },
          {
            name: "swaps",
            type: "tuple[]",
            components: [
              { name: "tokenIn", type: "address" },
              { name: "target", type: "address" },
              { name: "data", type: "bytes" },
              { name: "amountInOffset", type: "uint256" },
            ],
          },
        ],
      },
    ],
    [{ reserveId: a.debtReserveId, amount: repayAmount, liquidity, amount0Min: mins[0]!, amount1Min: mins[1]!, swaps }],
  );
  const hfBefore = await e.healthFactor(m, a);
  const gBefore = await e.balance(m.debtAsset, lp);
  await e.must("repay with collateral", lp, m.adapter, aaveAdapterAbi, "allowWithdraw", [m.flashloanRepay, p.key, liquidity, data]);
  const debt2 = await e.debt(m, a);
  const gAfter = await e.balance(m.debtAsset, lp);
  const rec2 = await e.record(m, p.key);
  n.repayWithCollateral = `liquidity ${liquidity} of ${rec.liquidity} (mins ${mins.join("/")}); repay ${fmt(repayAmount, d)}; debt ${fmt(debt1, d)} -> ${fmt(debt2, d)}; wallet +${fmt(gAfter - gBefore, d)} ${e.sym(m.debtAsset)}; record liquidity ${rec2.liquidity}; HF ${fmt(hfBefore, 18)} -> ${fmt(await e.healthFactor(m, a), 18)}`;
  if (debt1 - debt2 < repayAmount - repayAmount / 1_000n || rec.liquidity - rec2.liquidity !== liquidity || gAfter <= gBefore) {
    return { ok: false, detail: "repay with collateral did not repay the amount from the liquidity, or left the wallet nothing" };
  }

  const ok = await repayAllAndWithdraw(e, m, lp, a, p);
  return { ok, detail: ok ? "pledge, borrow, fees, repay with collateral, repay all, withdraw" : "debt, NFT or supply not cleared" };
}

// ─── 2. Slipstream LP: pledge, borrow USDC, withdraw part, add liquidity ───

async function slipstreamLifecycle(e: Env) {
  const m = e.market("slip-USDC-USDT-cl1");
  const lp = WALLETS.slipstreamLp;
  const n = e.numbers;
  n.settle = await e.settle();
  const p = await e.mintPosition(m, lp, 50_000n);
  n.position = `generation ${e.generation(m)} NPM ${p.npm} tokenId ${p.tokenId} key ${p.key}`;
  const a = await e.pledge(m, lp, p);
  n.pledge = `market ${m.key} (${m.kind}); account ${a.proxy}; credit ${a.credit}; collateral ${usd8(await e.collateralUsd8(m, a))}`;
  const d = e.dec(m.debtAsset);
  const amount = 15_000n * 10n ** BigInt(d);
  n.liquidity = await e.ensureLiquidity(m, amount);
  const before = await e.balance(m.debtAsset, lp);
  await e.borrow(m, lp, a, amount);
  const got = (await e.balance(m.debtAsset, lp)) - before;
  const debt = await e.debt(m, a);
  n.borrow = `${fmt(amount, d)} ${e.sym(m.debtAsset)}; wallet +${fmt(got, d)}; debt ${fmt(debt, d)}; HF ${fmt(await e.healthFactor(m, a), 18)}`;
  if (got !== amount || debt < amount) return { ok: false, detail: "borrow did not move the wallet and the debt by the amount" };

  // Withdraw a fifth of the record's liquidity as tokens; the position stays pledged.
  const rec = await e.record(m, p.key);
  const liquidity = rec.liquidity / 5n;
  const mins = p.amounts.map((x) => pct((x * liquidity) / p.liquidity, 9_000n));
  const b0 = await e.balance(m.token0, lp);
  const b1 = await e.balance(m.token1, lp);
  const supplied0 = await e.supplied(m, a);
  const w = await e.must("withdraw part", lp, m.adapter, aaveAdapterAbi, "withdraw", [p.key, liquidity, mins[0], mins[1], lp]);
  const burned = w.result as bigint;
  const r0 = (await e.balance(m.token0, lp)) - b0;
  const r1 = (await e.balance(m.token1, lp)) - b1;
  const supplied1 = await e.supplied(m, a);
  n.withdrawPart = `liquidity ${liquidity} of ${rec.liquidity} (mins ${mins.join("/")}); paid ${fmt(r0, e.dec(m.token0))} ${e.sym(m.token0)} + ${fmt(r1, e.dec(m.token1))} ${e.sym(m.token1)}; burned ${burned}; supplied ${supplied0} -> ${supplied1}; HF ${fmt(await e.healthFactor(m, a), 18)}`;
  if (r0 < mins[0]! || r1 < mins[1]! || r0 + r1 === 0n || supplied0 - supplied1 !== burned || burned === 0n) {
    return { ok: false, detail: "the partial withdraw paid or burned the wrong amounts" };
  }

  // Add liquidity to the pledged position through the adapter: the LPVault pulls the tokens, the new credit is supplied.
  const add0 = e.amountForUsd(m.token0, 10_000n);
  const add1 = e.amountForUsd(m.token1, 10_000n);
  await e.mint(m.token0, lp, add0);
  await e.mint(m.token1, lp, add1);
  await e.approve(lp, m.token0, m.lpVault, add0);
  await e.approve(lp, m.token1, m.lpVault, add1);
  const r = await e.must("addLiquidity", lp, m.adapter, aaveAdapterAbi, "addLiquidity", [p.key, add0, add1, 0n, 0n]);
  const [added, credit] = r.result as readonly [bigint, bigint, bigint, bigint];
  const supplied2 = await e.supplied(m, a);
  const rec2 = await e.record(m, p.key);
  n.addLiquidity = `liquidity +${added}, credit +${credit}; supplied ${supplied1} -> ${supplied2}; record liquidity ${rec2.liquidity}; HF ${fmt(await e.healthFactor(m, a), 18)}`;
  const ok = added > 0n && credit > 0n && supplied2 - supplied1 === credit && rec2.liquidity === rec.liquidity - liquidity + added;
  return { ok, detail: ok ? "pledge, borrow USDC, withdraw part, add liquidity and its credit supplied" : "addLiquidity did not supply the added credit" };
}

// ─── 3. Uniswap v4 LP: pledge (paid through Permit2), borrow GHO, fees, repay, withdraw ───

async function uniswapV4Lifecycle(e: Env) {
  const m = e.market("univ4-USDC-USDT-100");
  const lp = WALLETS.uniswapV4Lp;
  const n = e.numbers;
  n.settle = await e.settle();
  const p = await e.mintPosition(m, lp, 50_000n);
  n.position = `tokenId ${p.tokenId} key ${p.key}; minted ${fmt(p.amounts[0], e.dec(m.token0))} ${e.sym(m.token0)} + ${fmt(p.amounts[1], e.dec(m.token1))} ${e.sym(m.token1)} on [${m.bandLower}, ${m.bandUpper}]`;
  const a = await e.pledge(m, lp, p);
  n.pledge = `market ${m.key} (${m.kind}); account ${a.proxy}; credit ${a.credit}; collateral ${usd8(await e.collateralUsd8(m, a))}`;
  const d = e.dec(m.debtAsset);
  const amount = 20_000n * 10n ** BigInt(d);
  n.liquidity = await e.ensureLiquidity(m, amount);
  const before = await e.balance(m.debtAsset, lp);
  await e.borrow(m, lp, a, amount);
  const got = (await e.balance(m.debtAsset, lp)) - before;
  const debt1 = await e.debt(m, a);
  n.borrow = `${fmt(amount, d)} ${e.sym(m.debtAsset)}; wallet +${fmt(got, d)}; debt ${fmt(debt1, d)}; HF ${fmt(await e.healthFactor(m, a), 18)}`;
  if (got !== amount || debt1 < amount) return { ok: false, detail: "borrow did not move the wallet and the debt by the amount" };

  // Fees: alternating exact-input swaps on the market's v4 pool through the world's pool actor.
  const leg0 = e.amountForUsd(m.token0, 20_000n);
  const leg1 = e.amountForUsd(m.token1, 20_000n);
  for (let i = 0; i < 6; i++) n.swaps = await e.swapV4(m, i % 2 === 0, i % 2 === 0 ? leg0 : leg1);
  const fees = await collect(e, m, lp, p);
  if (fees.f0 === 0n || fees.f1 === 0n || !fees.matches) return { ok: false, detail: "collectFees did not pay fees in both tokens, or not what it returned" };

  const ok = await repayAllAndWithdraw(e, m, lp, a, p);
  return { ok, detail: ok ? "Uniswap v4: pledge, borrow, fees in both tokens, repay all, withdraw" : "debt, NFT or supply not cleared" };
}

// ─── 4. Price paths ───

/**
 * The stateless LPOracle prices both tokens from Aave V4's AaveOracle on every read: a drift, a crash and a depeg are
 * served at once, with no pool check, cap or grace window, and an old round is still served (no staleness gate: a
 * revert there would stop liquidations as well as borrows; oracle DESIGN.md).
 */
async function pricePaths(e: Env) {
  const mw = e.market("uni-WETH-USDC-500");
  const ms = e.market("uni-USDC-USDT-100");
  const n = e.numbers;
  const fails: string[] = [];
  const expect = (cond: boolean, what: string) => {
    if (!cond) fails.push(what);
  };
  const w0 = e.prices.WETH!;
  const u0 = e.prices.USDC!;
  const t0 = e.prices.USDT!;
  n.settle = await e.settle();
  const s0 = await e.lpPrice(mw);
  n["0.baseline"] = `WETH market ${usd8(s0)}; stable market ${usd8(await e.lpPrice(ms))}`;

  // 1. A slow drift (WETH down 0.6 %), then crashes of 30, 60 and 90 %: the answer falls with each round, the pool
  // unmoved.
  let last = s0;
  for (const bps of [9_940n, 7_000n, 4_000n, 1_000n]) {
    await e.refresh({ WETH: pct(w0, bps), USDC: u0 });
    const s = await e.lpPrice(mw);
    n[`1.weth-${bps}bps`] = usd8(s);
    expect(s < last, `WETH at ${bps} bps: the answer did not fall`);
    last = s;
  }
  await e.refresh({ WETH: w0, USDC: u0 });

  // 2. USDT depeg on the stable market: the token price is Aave's, which follows the feed down.
  for (const [label, price] of [
    ["0.95", 95_000_000n],
    ["0.80", 80_000_000n],
  ] as const) {
    await e.refresh({ USDT: price, USDC: u0 });
    const [p0, p1] = (await e.read(ms.lpOracle, lpOracleAbi, "getPrices")) as readonly [bigint, bigint, bigint];
    n[`2.depeg-${label}`] = `answer ${usd8(await e.lpPrice(ms))}; token prices ${usd8(p0)}, ${usd8(p1)}`;
    expect([p0, p1].some((p) => p <= price), `USDT ${label}: no token priced at or below ${usd8(price)}`);
  }
  await e.refresh({ USDT: t0, USDC: u0 });

  // 3. No staleness gate: past a heartbeat and its margin, the same answer is still served.
  const fresh = await e.lpPrice(mw);
  await e.advance(STALE_AFTER + 2);
  const aged = await e.lpPrice(mw).catch(() => -1n);
  n["3.aged"] = `answer ${usd8(fresh)} -> ${aged < 0n ? "reverted" : usd8(aged)} after ${STALE_AFTER + 2} s`;
  expect(aged === fresh, "the answer changed or stopped after the feed aged");
  n.restored = await e.settle(true);
  return { ok: fails.length === 0, detail: fails.length === 0 ? "drift, crashes, depeg, and an aged round still served" : fails.join("; ") };
}

// ─── 5. Keeper liquidations through the LiquidationModule ───

const keeperOf = (e: Env) => ((e.ctx.manifest.roles?.keepers as Address[] | undefined)?.[0] ?? (e.ctx.config.keepers as Address[])[0]!) as Address;

async function keeperLiquidations(e: Env) {
  const um = e.market("uni-WETH-USDC-500");
  const sm = e.market("slip-WETH-USDC-cl100");
  const keeper = keeperOf(e);
  const n = e.numbers;
  n.settle = await e.settle();
  const accounts: { m: Market; a: Account; label: string }[] = [];
  for (const [m, w, label] of [
    [um, WALLETS.uniswapBorrower, "uniswap"],
    [sm, WALLETS.slipstreamBorrower, "slipstream"],
  ] as const) {
    const p = await e.mintPosition(m, w, 50_000n);
    const a = await e.pledge(m, w, p);
    const max = await e.maxBorrow(m, w, a);
    const amount = pct(max, 9_700n);
    n[`${label}.liquidity`] = await e.ensureLiquidity(m, amount);
    await e.borrow(m, w, a, amount);
    n[`${label}.borrow`] = `${m.name}: collateral ${usd8(await e.collateralUsd8(m, a))}; borrowed ${fmt(amount, e.dec(m.debtAsset))} ${e.sym(m.debtAsset)} of max ${fmt(max, e.dec(m.debtAsset))}; HF ${fmt(await e.healthFactor(m, a), 18)}`;
    accounts.push({ m, a, label });
  }
  // WETH falls far enough that both accounts end near HF 0.85 (full-range value moves with sqrt(price)).
  let hfMax = 0n;
  for (const x of accounts) {
    const hf = await e.healthFactor(x.m, x.a);
    if (hf > hfMax) hfMax = hf;
  }
  const bps = Env.crashBpsFor(hfMax, 85n * 10n ** 16n, 7_000n);
  await e.setWeth(bps);
  n.crash = `WETH to ${bps} bps of ${usd8(e.prices.WETH!)}: ${usd8(pct(e.prices.WETH!, bps))}`;
  let ok = true;
  const detail: string[] = [];
  for (const x of accounts) {
    const hf = await e.healthFactor(x.m, x.a);
    n[`${x.label}.hf`] = fmt(hf, 18);
    if (hf >= WAD) {
      ok = false;
      detail.push(`${x.label}: HF ${fmt(hf, 18)} not below 1`);
      continue;
    }
    const r = await e.liquidate(x.m, x.a, keeper, x.label);
    if (!r.ok || r.debtAfter >= r.debtBefore || r.amount0 + r.amount1 === 0n || r.spent !== r.debtRepaid) {
      ok = false;
      detail.push(`${x.label}: ${r.ok ? "debt not reduced, no pool tokens paid, or more taken than repaid" : r.error}`);
    }
  }
  n.restored = await e.settle();
  return { ok, detail: ok ? `keeper ${keeper} liquidated on ${um.name} and ${sm.name}, paid in both pool tokens` : detail.join("; ") };
}

// ─── 6. Keeper liquidation on a Uniswap v4 market of a borrower the USDC issuer has blocked ───

/**
 * The borrower holds a native ETH/USDC position with fees in both tokens and is then blocked by the local USDC (a
 * BlocklistToken, as Circle can block an address). A liquidation pays nothing to the borrower: the LPVault keeps the
 * fees the AMM pays during the unwind for the position, and both pool tokens go to the liquidator, so the block cannot
 * stop it. The borrower is unblocked at the end.
 */
async function uniswapV4BlockedBorrowerLiquidation(e: Env) {
  const m = e.market("univ4-ETH-USDC-500");
  const w = WALLETS.uniswapV4Borrower;
  const keeper = keeperOf(e);
  const usdc = e.token("USDC");
  const minter = (await e.read(usdc, ERC20, "MINTER")) as Address;
  const n = e.numbers;
  n.settle = await e.settle();
  const p = await e.mintPosition(m, w, 50_000n);
  const a = await e.pledge(m, w, p);
  const max = await e.maxBorrow(m, w, a);
  const amount = pct(max, 9_700n);
  n.liquidity = await e.ensureLiquidity(m, amount);
  await e.borrow(m, w, a, amount);
  n.borrow = `${m.name}: collateral ${usd8(await e.collateralUsd8(m, a))}; borrowed ${fmt(amount, e.dec(m.debtAsset))} ${e.sym(m.debtAsset)} of max ${fmt(max, e.dec(m.debtAsset))}; HF ${fmt(await e.healthFactor(m, a), 18)}`;
  // Fees in both tokens: one exact-input swap each way.
  n.swaps = [await e.swapV4(m, true, e.amountForUsd(m.token0, 10_000n)), await e.swapV4(m, false, e.amountForUsd(m.token1, 10_000n))].join("; ");
  const fees = (await e.read(m.lpVault, lpVaultAbi, "feesOf", [p.key])) as readonly [bigint, bigint];
  n.fees = `feesOf ${fees.join("/")}`;
  if (!fees.some((f) => f > 0n)) return { ok: false, detail: "no fees accrued on the position, so the unwind would not meet the blocked token" };
  await e.gasFor(minter);
  await e.must("block the borrower", minter, usdc, BLOCKLIST, "setBlocked", [w, true]);
  try {
    n.blocked = `USDC isBlocked(${w}) ${await e.read(usdc, BLOCKLIST, "isBlocked", [w])}`;
    const bps = Env.crashBpsFor(await e.healthFactor(m, a), 85n * 10n ** 16n, 7_000n);
    await e.setWeth(bps);
    n.crash = `WETH to ${bps} bps of ${usd8(e.prices.WETH!)}: ${usd8(pct(e.prices.WETH!, bps))}`;
    const hf = await e.healthFactor(m, a);
    n.hf = fmt(hf, 18);
    if (hf >= WAD) return { ok: false, detail: `HF ${fmt(hf, 18)} not below 1 after the crash` };
    const usdcBefore = await e.balance(usdc, w);
    const r = await e.liquidate(m, a, keeper, "v4-blocked");
    const usdcAfter = await e.balance(usdc, w);
    n.feesAfter = `feesOf ${((await e.read(m.lpVault, lpVaultAbi, "feesOf", [p.key])) as readonly bigint[]).join("/")}`;
    const ok = r.ok && r.debtAfter < r.debtBefore && r.amount0 + r.amount1 > 0n && usdcAfter === usdcBefore;
    if (ok) return { ok, detail: `keeper ${keeper} liquidated a blocked borrower on ${m.name}; the borrower's USDC did not move` };
    return { ok, detail: r.ok ? "debt not reduced, liquidator not paid, or the blocked borrower's USDC moved" : `liquidation of the blocked borrower reverted: ${r.error}` };
  } finally {
    await e.must("unblock the borrower", minter, usdc, BLOCKLIST, "setBlocked", [w, false]);
    n.restored = await e.settle();
  }
}

// ─── 7. Self-liquidation attempt ───

async function selfLiquidation(e: Env) {
  const m = e.market("uni-WETH-USDC-500");
  const b = WALLETS.selfLiquidator;
  const n = e.numbers;
  n.settle = await e.settle();
  const p = await e.mintPosition(m, b, 50_000n);
  const a = await e.pledge(m, b, p);
  const max = await e.maxBorrow(m, b, a);
  const amount = pct(max, 9_700n);
  n.liquidity = await e.ensureLiquidity(m, amount);
  await e.borrow(m, b, a, amount);
  const d = e.dec(m.debtAsset);
  const cover = 1_000n * 10n ** BigInt(d);
  await e.mint(m.debtAsset, b, cover);
  await e.approve(b, m.debtAsset, m.liquidationModule, cover);
  await e.approve(b, m.debtAsset, m.spoke, cover);
  const params = { marketId: m.marketId, debtReserveId: a.debtReserveId, account: a.proxy, debtToCover: cover, minAmount0: 0n, minAmount1: 0n, receiver: b };

  // (1) Healthy account: the borrower's own LiquidationModule.liquidate.
  const hf1 = await e.healthFactor(m, a);
  const r1 = await e.tryCall(b, m.liquidationModule, liquidationModuleAbi, "liquidate", [params]);
  n["1.healthy.LiquidationModule.liquidate"] = `HF ${fmt(hf1, 18)}: ${r1.reverted ? `reverted ${r1.name}` : "SUCCEEDED"}`;

  // (2) Underwater account: the borrower calls the CDP Spoke's liquidationCall on its own account directly; only the
  // LiquidationModule may receive seized vault tokens.
  const bps = Env.crashBpsFor(hf1, 85n * 10n ** 16n, 7_000n);
  await e.setWeth(bps);
  const hf2 = await e.healthFactor(m, a);
  const r2 = await e.tryCall(b, m.spoke, aaveV4SpokeAbi, "liquidationCall", [a.collateralReserveId, a.debtReserveId, a.proxy, cover, false]);
  n["2.underwater.Spoke.liquidationCall"] = `WETH at ${bps} bps, HF ${fmt(hf2, 18)}: ${r2.reverted ? `reverted ${r2.name}` : "SUCCEEDED"}`;

  // (3) Recorded, not asserted: the borrower's own LiquidationModule.liquidate while underwater (simulated only; the
  // module is open to anyone, so this is an ordinary liquidation paid at the bonus).
  const r3 = await e.tryCall(b, m.liquidationModule, liquidationModuleAbi, "liquidate", [params]);
  n["3.underwater.LiquidationModule.liquidate (simulated)"] = r3.reverted
    ? `reverted ${r3.name}`
    : `would succeed: repaid ${fmt(r3.result.debtRepaid, d)}, paid ${r3.result.amount0}/${r3.result.amount1}, fee units ${r3.result.feeUnits}`;
  n.restored = await e.settle();
  const ok = r1.reverted && r2.reverted && hf2 < WAD;
  return {
    ok,
    detail: ok
      ? `own-account liquidation refused: LiquidationModule ${r1.name}; Spoke ${r2.name}`
      : `${r1.reverted ? "" : "healthy LiquidationModule.liquidate succeeded; "}${r2.reverted ? "" : "direct Spoke.liquidationCall succeeded; "}${hf2 < WAD ? "" : "HF not below 1 after the crash"}`,
  };
}

// ─── 8. Deficit after a 90 % crash, covered by the First-Loss Reserve ───

async function deficitCoverage(e: Env) {
  const m = e.market("uni-WETH-USDC-500");
  const b = WALLETS.deficitBorrower;
  const keeper = keeperOf(e);
  // The coverage caller of 08_AaveLossLayersPayload: its config's, else the Aave governance executor.
  const caller = (e.ctx.config.aavePayload?.lossLayerRoles?.coverageCaller ?? e.ctx.config.aave?.governanceExecutor ?? e.ctx.actors.aaveExecutor) as Address;
  const n = e.numbers;
  n.settle = await e.settle();
  const p = await e.mintPosition(m, b, 50_000n);
  const a = await e.pledge(m, b, p);
  const max = await e.maxBorrow(m, b, a);
  const amount = pct(max, 9_900n);
  n.liquidity = await e.ensureLiquidity(m, amount);
  await e.borrow(m, b, a, amount);
  const d = e.dec(m.debtAsset);
  const coll = await e.collateralUsd8(m, a);
  const debt = await e.debt(m, a);
  const debtUsd = (debt * ONE_USD) / 10n ** BigInt(d);
  // A deficit needs collateral below debt times the liquidation bonus. Full-range value moves with sqrt(price): a
  // 90 % crash leaves sqrt(0.1) = 31.6 % of the value; a deeper one is used when that still covers debt × bonus × 0.95.
  const bonus = await e.maxLiquidationBonus(m);
  const target = (debtUsd * bonus * 9_500n) / (10_000n * 10_000n);
  const r = (target * target * 10_000n) / (coll * coll);
  const bps = r < 1_000n ? r : 1_000n;
  n.position = `collateral ${usd8(coll)} debt ${fmt(debt, d)} ${e.sym(m.debtAsset)} HF ${fmt(await e.healthFactor(m, a), 18)}; max bonus ${bonus} bps; crash to ${bps} bps (${10_000n - bps} bps down)`;
  await e.setWeth(bps);
  n.crash = `collateral ${usd8(await e.collateralUsd8(m, a))} vs debt ${usd8(debtUsd)}; HF ${fmt(await e.healthFactor(m, a), 18)}`;

  const hubAbi = withErrors(aaveV4HubAbi);
  const assetId = (await e.read(m.hub, hubAbi, "getAssetId", [m.debtAsset])) as bigint;
  const defBefore = (await e.read(m.hub, hubAbi, "getSpokeDeficitRay", [assetId, m.spoke])) as bigint;
  const liq = await e.liquidate(m, a, keeper, "liquidation");
  const defAfter = (await e.read(m.hub, hubAbi, "getSpokeDeficitRay", [assetId, m.spoke])) as bigint;
  const left = await e.supplied(m, a);
  n.deficit = `Spoke deficit ${fmt(defBefore, 27 + d)} -> ${fmt(defAfter, 27 + d)} ${e.sym(m.debtAsset)}; account debt ${fmt(liq.debtAfter, d)} supplied units ${left}`;
  if (!liq.ok || defAfter <= defBefore) {
    n.restored = await e.settle();
    return { ok: false, detail: liq.ok ? "no deficit recorded on the CDP Spoke" : `liquidation reverted: ${liq.error}` };
  }

  // The First-Loss Reserve of (Hub, asset) covers the deficit: the manifest's, the one the RiskModule registered.
  const layer = (e.ctx.manifest.coverage.firstLossReserves as { address: Address; hub: Address; asset: Address; hubLabel: string; symbol: string }[]).find(
    (l) => eq(l.hub, m.hub) && eq(l.asset, m.debtAsset),
  );
  if (!layer) throw new StepError(`no First-Loss Reserve of ${e.sym(m.debtAsset)} on Hub ${m.hub} in the manifest`);
  const cs = layer.address;
  const registered = (await e.read(m.riskModule, riskModuleAbi, "getDebtReserve", [m.spoke, a.debtReserveId])).firstLossReserve as Address;
  const allowed = (await e.read(cs, firstLossReserveAbi, "isAllowedSpoke", [m.spoke])) as boolean;
  let funded0 = (await e.read(cs, firstLossReserveAbi, "fundedBalance")) as bigint;
  const need = defAfter / RAY + 1n;
  let topUp = 0n;
  if (funded0 < need) {
    topUp = need - funded0 + 10n ** BigInt(d);
    const funder = (e.ctx.config.coverage?.funder ?? e.ctx.actors.deployer) as Address;
    await e.mint(m.debtAsset, funder, topUp);
    await e.approve(funder, m.debtAsset, cs, topUp);
    await e.must("fund", funder, cs, firstLossReserveAbi, "fund", [topUp]);
    funded0 = (await e.read(cs, firstLossReserveAbi, "fundedBalance")) as bigint;
  }
  await e.gasFor(caller);
  // The funded balance earns the Hub's supply interest from block to block, so the check is on the First-Loss Reserve's
  // Hub shares, which do not accrue: they fall by exactly the shares `coverDeficit` reports, and the deficit is gone.
  const shares0 = (await e.read(cs, firstLossReserveAbi, "fundedShares")) as bigint;
  const c = await e.ctx.send(caller, cs, withErrors(firstLossReserveAbi), "coverDeficit", [m.spoke, maxUint256]);
  const defFinal = (await e.read(m.hub, hubAbi, "getSpokeDeficitRay", [assetId, m.spoke])) as bigint;
  const funded1 = (await e.read(cs, firstLossReserveAbi, "fundedBalance")) as bigint;
  const shares1 = (await e.read(cs, firstLossReserveAbi, "fundedShares")) as bigint;
  // From the mined DeficitCovered event: the simulated return is priced at the previous block's timestamp.
  const ev = c.ok
    ? (parseEventLogs({ abi: firstLossReserveAbi as any, logs: c.receipt!.logs, eventName: "DeficitCovered" }).find((l: any) => eq(l.address, cs)) as any)
    : undefined;
  const [burned, covered]: readonly [bigint, bigint] = ev ? [ev.args.shares as bigint, ev.args.covered as bigint] : [0n, 0n];
  const name = `${layer.hubLabel}/${layer.symbol}`;
  n.coverage = `First-Loss Reserve ${name} ${cs} (RiskModule ${eq(registered, cs) ? "agrees" : registered}); Spoke allowed ${allowed}; top-up ${fmt(topUp, d)}; coverDeficit by ${caller} ${c.ok ? `covered ${fmt(covered, d)} for ${burned} shares` : c.error}; deficit ${fmt(defAfter, 27 + d)} -> ${fmt(defFinal, 27 + d)}; funded ${fmt(funded0, d)} -> ${fmt(funded1, d)}; shares ${shares0} -> ${shares1}`;
  n.restored = await e.settle();
  const ok = c.ok && ev !== undefined && defFinal === 0n && covered === (defAfter + RAY - 1n) / RAY && burned > 0n && shares0 - shares1 === burned && eq(registered, cs);
  return {
    ok,
    detail: ok ? `deficit of ${fmt(covered, d)} ${e.sym(m.debtAsset)} covered by the ${name} First-Loss Reserve, ${burned} Hub shares burned` : "deficit not fully covered, or the First-Loss Reserve's shares did not fall by the shares burned",
  };
}

// ─── 9. Debt reserve covered by another Hub's First-Loss Reserve (refused) ───

/**
 * `RiskModule.setDebtReserve` takes a First-Loss Reserve only of the reserve's own Hub and asset. Simulated through
 * the AccessManager as the governance Safe after the delay (snapshot reverted): an unregistered reserve of a listed
 * Spoke, with another Hub's First-Loss Reserve of the same asset when one exists, else of another asset.
 */
async function foreignFirstLossReserve(e: Env) {
  const m = e.market("uni-USDC-USDT-100");
  const n = e.numbers;
  const layers = e.ctx.manifest.coverage.firstLossReserves as { address: Address; hub: Address; asset: Address; hubLabel: string; symbol: string }[];
  let pick: { spoke: Address; reserveId: bigint; layer: (typeof layers)[number]; riskModule: Address; how: string } | undefined;
  for (const x of e.markets) {
    if (pick?.how === "same asset") break;
    const count = (await e.read(x.spoke, aaveV4SpokeAbi, "getReserveCount")) as bigint;
    for (let id = 0n; id < count && pick?.how !== "same asset"; id++) {
      if (!/^0x0+$/.test((await e.read(x.riskModule, riskModuleAbi, "getDebtReserve", [x.spoke, id])).hub)) continue;
      const r = await e.read(x.spoke, aaveV4SpokeAbi, "getReserve", [id]);
      const same = layers.find((l) => eq(l.asset, r.underlying) && !eq(l.hub, r.hub));
      if (same) pick = { spoke: x.spoke, reserveId: id, layer: same, riskModule: x.riskModule, how: "same asset" };
      else if (!pick) {
        const other = layers.find((l) => !eq(l.hub, r.hub));
        if (other) pick = { spoke: x.spoke, reserveId: id, layer: other, riskModule: x.riskModule, how: "another asset" };
      }
    }
  }
  if (!pick) throw new StepError("no unregistered reserve on a listed Spoke, or no First-Loss Reserve of another Hub");
  const [isMember, delay] = (await e.read(e.accessManager, accessManagerAbi, "hasRole", [GOVERNANCE_ROLE, e.ctx.actors.governanceSafe])) as readonly [boolean, number];
  n.role = `governance Safe holds AVANA_GOVERNANCE_ROLE ${isMember} (delay ${delay} s)`;
  const data = encodeFunctionData({ abi: riskModuleAbi, functionName: "setDebtReserve", args: [pick.spoke, pick.reserveId, pick.layer.address] });
  const r = await e.governanceSimulate(pick.riskModule, data);
  n.setDebtReserve = `reserve ${pick.reserveId} on ${pick.spoke} with the ${pick.layer.hubLabel}/${pick.layer.symbol} First-Loss Reserve (${pick.how}) on ${m.name}'s RiskModule ${pick.riskModule === m.riskModule ? "" : `(${pick.riskModule}) `}: ${r.reverted ? `reverted ${r.name}` : "SUCCEEDED"}`;
  const ok = isMember && r.reverted && r.name.startsWith("InvalidFirstLossReserve");
  return { ok, detail: ok ? "a First-Loss Reserve of another Hub refused with InvalidFirstLossReserve" : "a First-Loss Reserve of another Hub was not refused with InvalidFirstLossReserve" };
}

// ─── Export ───

export function marketScenarios(ctx: ScenarioContext): Scenario[] {
  const s = (name: string, body: (e: Env) => Promise<{ ok: boolean; detail: string }>): Scenario => ({
    name,
    needs: "market",
    run: () => runWith(ctx, body),
  });
  return [
    s("LP pledges a Uniswap v3 position, borrows GHO, collects fees, repays with collateral, repays and withdraws", uniswapLifecycle),
    s("LP pledges a Slipstream position, borrows USDC, withdraws part and adds liquidity", slipstreamLifecycle),
    s("LP pledges a Uniswap v4 position, borrows GHO, collects fees, repays and withdraws", uniswapV4Lifecycle),
    s("price paths: slow drift, 30/60/90 % crashes, depeg, an aged round (stateless LPOracle on Aave's prices)", pricePaths),
    s("keeper liquidates through the LiquidationModule on a Uniswap pool and on a Slipstream pool", keeperLiquidations),
    s("keeper liquidates a borrower the USDC issuer has blocked on a Uniswap v4 market", uniswapV4BlockedBorrowerLiquidation),
    s("self-liquidation attempt by the borrower", selfLiquidation),
    s("deficit after a 90 % crash and First-Loss Reserve coverage", deficitCoverage),
    s("debt reserve with another Hub's First-Loss Reserve (must revert)", foreignFirstLossReserve),
  ];
}
