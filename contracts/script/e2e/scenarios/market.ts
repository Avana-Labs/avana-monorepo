// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Market scenarios of the local rehearsal, on the markets listed by script/deploy/09_ListMarkets.s.sol
// (deployments-local/<network>/listing-markets.json): an LP's whole life on a Uniswap v3 and on a Slipstream market,
// LPOracle price paths, keeper liquidations through LPVaultSwap, a self-liquidation attempt, a deficit covered by the
// First-Loss Reserve, and the cross-Hub credit line switch (off at launch). Each scenario uses its own wallet, starts from
// the world's configured feed prices and leaves them restored. Prices move only by signed OCR2 rounds
// (refresh-feeds.ts); pools move only by swaps through the world's routers.

import {
  type Address,
  type Hex,
  type TransactionReceipt,
  formatUnits,
  keccak256,
  maxUint256,
  parseAbi,
  parseEventLogs,
  stringToBytes,
  toHex,
} from "viem";
import {
  aaveAdapterAbi,
  aaveV4HubAbi,
  aaveV4SpokeAbi,
  collateralizationAbi,
  firstLossReserveAbi,
  debtOracleAbi,
  lensAbi,
  lpOracleAbi,
  lpVaultAbi,
  lpVaultSwapAbi,
  marketRegistryAbi,
  riskModuleAbi,
  vaultTokenAbi,
} from "../../../../packages/protocol/src/abis/index.ts";
import { refreshFeeds, worldFeeds } from "../refresh-feeds.ts";
import type { Scenario, ScenarioContext, ScenarioRun, SendResult } from "./context.ts";
import { transmit } from "./ocr2.ts";

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
  "struct IncreaseLiquidityParams { uint256 tokenId; uint256 amount0Desired; uint256 amount1Desired; uint256 amount0Min; uint256 amount1Min; uint256 deadline; }",
  "function mint(MintParams params) payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)",
  "function increaseLiquidity(IncreaseLiquidityParams params) payable returns (uint128 liquidity, uint256 amount0, uint256 amount1)",
]);
const UNI_ROUTER = parseAbi([
  "struct ExactInputSingleParams { address tokenIn; address tokenOut; uint24 fee; address recipient; uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96; }",
  "function exactInputSingle(ExactInputSingleParams params) payable returns (uint256 amountOut)",
]);
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
  ...lpVaultSwapAbi,
  ...aaveAdapterAbi,
  ...collateralizationAbi,
  ...vaultTokenAbi,
  ...lpVaultAbi,
  ...riskModuleAbi,
  ...marketRegistryAbi,
  ...firstLossReserveAbi,
  ...aaveV4SpokeAbi,
  ...aaveV4HubAbi,
].filter((i: any) => i.type === "error") as readonly unknown[];
const withErrors = (abi: readonly unknown[]) => [...abi, ...ERRORS] as readonly unknown[];

// ─── Constants ───

const WAD = 10n ** 18n;
const RAY = 10n ** 27n;
const ONE_USD = 100_000_000n;
/** Gas for `poke()`: the LPOracle's and the DebtOracle's `pokeMinGas` is 1,000,000 at entry. */
const POKE_GAS = 1_500_000n;
const STATES = ["Live", "Drifting", "Cached", "Expired"] as const;
const LIVE = 0;
const DRIFTING = 1;
const CACHED = 2;
const EXPIRED = 3;
// LPOracle reason bits (LPOracleTypes.sol, LPOracleCodes).
const USD_BAND = 1n << 3n;
const CONSISTENCY_DEVIATION = 1n << 4n;
const PRICE_CLAMPED = 1n << 6n;
const IN_GRACE = 1n << 10n;
const QUOTE_CHANGE_CAPPED = 1n << 18n;
/** Feed age past which a leg is stale: heartbeat 86,400 s plus margin 1,800 s. */
const STALE_AFTER = 88_200;
/** The symbols the four listed markets and their debt reserves read. */
const MARKET_SYMBOLS = ["USDC", "USDT", "WETH", "GHO"] as const;

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
  poker: "0x1000000000000000000000000000000000000c0f",
} as const satisfies Record<string, Address>;

// ─── Types ───

/** One market of listing-markets.json. */
interface Market {
  readonly name: string;
  readonly marketId: bigint;
  readonly integrationId: number;
  readonly spokeLabel: string;
  readonly spoke: Address;
  readonly hub: Address;
  readonly pool: Address;
  readonly token0: Address;
  readonly token1: Address;
  readonly tickLower: number;
  readonly tickUpper: number;
  readonly decimals: number;
  readonly lpVault: Address;
  readonly lpOracle: Address;
  readonly debtAsset: Address;
  readonly maxLiquidationBonus: bigint;
  readonly vaultToken: Address;
}

interface Position {
  readonly tokenId: bigint;
  readonly key: Hex;
  readonly npm: Address;
  readonly ref: { integrationId: number; positionKey: Hex };
  readonly amounts: readonly [bigint, bigint];
}

interface Account {
  readonly proxy: Address;
  readonly credited: bigint;
  readonly collateralReserveId: bigint;
  readonly debtReserveId: bigint;
}

/** Raised by a step whose failure ends the scenario; `run` turns it into a fail with the numbers so far. */
class StepError extends Error {}

// ─── Small helpers ───

const eq = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
const pct = (x: bigint, bps: bigint) => (x * bps) / 10_000n;
const fmt = (x: bigint, decimals: number) => formatUnits(x, decimals);
const usd8 = (x: bigint) => `$${formatUnits(x, 8)}`;
const stateName = (s: number) => STATES[s] ?? `state ${s}`;

function isqrt(n: bigint): bigint {
  if (n < 2n) return n;
  let x = n;
  let y = (x + 1n) / 2n;
  while (y < x) {
    x = y;
    y = (x + n / x) / 2n;
  }
  return x;
}

/** `sqrt(raw1 / raw0) × 2^96` at USD prices `p0`, `p1` (8 decimals), as 02_DeployWorld initialises its pools. */
const sqrtPriceX96 = (p0: bigint, p1: bigint, d0: number, d1: number) =>
  isqrt((p0 * 10n ** BigInt(d1) * (1n << 192n)) / (p1 * 10n ** BigInt(d0)));

/** The first revert reason viem decoded along an error's cause chain, else its first line. */
function errorName(e: unknown): string {
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

class Env {
  readonly ctx: ScenarioContext;
  readonly numbers: Record<string, string> = {};
  readonly adapter: Address;
  readonly lpVaultSwap: Address;
  readonly lens: Address;
  readonly registry: Address;
  readonly timelock: Address;
  readonly markets: Market[];
  readonly prices: Record<string, bigint>;
  readonly decimalsOf: Record<string, number>;
  readonly symbolOf: Record<string, string>;
  private readonly minters: Record<string, Address> = {};

  constructor(ctx: ScenarioContext) {
    this.ctx = ctx;
    const a = ctx.manifest.avana;
    this.adapter = a.aaveAdapter.address;
    this.lpVaultSwap = a.lpVaultSwap.address;
    this.lens = a.lens.address;
    this.registry = a.marketRegistry.address;
    this.timelock = a.timelock.address;
    const listing = ctx.file("listing-markets.json");
    if (!listing) throw new StepError("no listing-markets.json (09_ListMarkets has not run)");
    this.markets = Object.values(listing).map((m: any) => ({
      name: m.name,
      marketId: BigInt(m.marketId),
      integrationId: Number(m.integrationId),
      spokeLabel: m.spokeLabel,
      spoke: m.spoke,
      hub: m.hub,
      pool: m.pool,
      token0: m.token0,
      token1: m.token1,
      tickLower: Number(m.tickLower),
      tickUpper: Number(m.tickUpper),
      decimals: Number(m.decimals),
      lpVault: m.lpVault,
      lpOracle: m.lpOracle,
      debtAsset: m.debtAsset,
      maxLiquidationBonus: BigInt(m.maxLiquidationBonus),
      vaultToken: m.vaultToken,
    }));
    this.prices = {};
    this.decimalsOf = {};
    for (const t of ctx.config.world.tokens as { symbol: string; decimals: number; price8: number | string }[]) {
      this.prices[t.symbol] = BigInt(t.price8);
      this.decimalsOf[t.symbol] = t.decimals;
    }
    this.symbolOf = {};
    for (const [sym, addr] of Object.entries(ctx.world.tokens ?? {})) this.symbolOf[(addr as string).toLowerCase()] = sym;
  }

  market(name: string): Market {
    const m = this.markets.find((x) => x.name === name);
    if (!m) throw new StepError(`market ${name} not in listing-markets.json`);
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
    const v = (this.ctx.manifest.avana.lpVaults as { address: string; kind: string }[]).find((x) => eq(x.address, m.lpVault));
    return v ? v.kind === "slipstream" : m.name.startsWith("slip");
  }

  generation(m: Market): number {
    const cfg = (this.ctx.config.listing.markets as { name: string; generation?: number }[]).find((x) => x.name === m.name);
    return cfg?.generation ?? 0;
  }

  read(address: Address, abi: readonly unknown[], fn: string, args: readonly unknown[] = []) {
    return this.ctx.read(address, abi, fn, args);
  }

  /** Sends and throws a StepError naming `step` on any failure. */
  async must(step: string, from: Address, to: Address, abi: readonly unknown[], fn: string, args: readonly unknown[], opts: { gas?: bigint } = {}) {
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

  async refresh(prices: Record<string, bigint>, symbols?: readonly string[]) {
    await refreshFeeds(this.ctx.client, this.ctx.network, { symbols: symbols ?? Object.keys(prices), prices });
  }

  async poke(oracle: Address, abi: readonly unknown[] = lpOracleAbi): Promise<SendResult> {
    await this.gasFor(WALLETS.poker);
    return this.ctx.send(WALLETS.poker, oracle, withErrors(abi), "poke", [], { gas: POKE_GAS });
  }

  async priceState(oracle: Address): Promise<any> {
    return this.read(oracle, lpOracleAbi, "getPriceState");
  }

  describe(s: any): string {
    return `${stateName(Number(s.state))} answer ${usd8(BigInt(s.answer))} accepted ${usd8(BigInt(s.acceptedAnswer))} reasons 0x${BigInt(s.reasons).toString(16)} liqPaused ${s.liquidationPaused} grace ${s.inGrace} borrowAllowed ${s.borrowAllowed}`;
  }

  /** Every DebtOracle (non-fixed price source) of the listed markets' CDP Spokes. */
  async debtOracles(): Promise<Address[]> {
    const outList: Address[] = [];
    const spokes = [...new Set(this.markets.map((m) => m.spoke.toLowerCase()))] as Address[];
    for (const spoke of spokes) {
      const ids = (await this.read(this.registry, marketRegistryAbi, "getDebtReserveIds", [spoke])) as bigint[];
      for (const id of ids) {
        const d = await this.read(this.registry, marketRegistryAbi, "getDebtReserve", [spoke, id]);
        if (!d.fixedPrice && !outList.some((o) => eq(o, d.priceSource))) outList.push(d.priceSource);
      }
    }
    return outList;
  }

  /**
   * Restores the configured prices (one fresh round per feed of `symbols`, all world symbols when `all`), pokes every
   * listed LPOracle and DebtOracle, and waits out any grace window so the next step starts Live and outside grace.
   */
  async settle(all = false): Promise<string> {
    const symbols = all ? Object.keys(this.prices) : [...MARKET_SYMBOLS];
    const prices: Record<string, bigint> = {};
    for (const s of symbols) if (this.prices[s] !== undefined) prices[s] = this.prices[s]!;
    await this.refresh(prices, symbols);
    const debt = await this.debtOracles();
    let notes = "";
    for (let round = 0; round < 3; round++) {
      let grace = false;
      notes = "";
      for (const m of this.markets) {
        await this.poke(m.lpOracle);
        const s = await this.priceState(m.lpOracle);
        grace ||= Boolean(s.inGrace);
        notes += `${m.name} ${stateName(Number(s.state))}${s.inGrace ? " (grace)" : ""}; `;
      }
      for (const o of debt) {
        await this.poke(o, debtOracleAbi);
        const s = await this.read(o, debtOracleAbi, "getPriceState");
        grace ||= Boolean(s.inGrace);
        notes += `DebtOracle ${o.slice(0, 8)} ${stateName(Number(s.state))}${s.inGrace ? " (grace)" : ""}; `;
      }
      if (!grace) break;
      const graceDuration = Number(this.ctx.config.parameters?.globals?.graceDuration ?? 1800);
      await this.advance(graceDuration + 1);
      await this.refresh(prices, symbols);
    }
    return notes.trim();
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
      {
        tokenIn,
        tokenOut,
        fee,
        recipient: WALLETS.swapper,
        deadline: await this.deadline(),
        amountIn,
        amountOutMinimum: 0n,
        sqrtPriceLimitX96: target,
      },
    ]);
    const after = (await this.read(pool, POOL, "slot0")) as readonly [bigint, number];
    return `sqrtPriceX96 ${cur} -> ${after[0]} (tick ${after[1]})`;
  }

  // ─── Positions and accounts ───

  /** Mints an exact-range position of the market, worth about `usdEach` of each token, and approves the LPVault. */
  async mintPosition(m: Market, owner: Address, usdEach: bigint): Promise<Position> {
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
      tickLower: m.tickLower,
      tickUpper: m.tickUpper,
      amount0Desired: a0,
      amount1Desired: a1,
      amount0Min: 0n,
      amount1Min: 0n,
      recipient: owner,
      deadline: await this.deadline(),
    };
    const r = slip
      ? await this.must("Slipstream mint", owner, npm, SLIP_NPM, "mint", [
          { ...base, tickSpacing: Number(await this.read(m.pool, POOL, "tickSpacing")), sqrtPriceX96: 0n },
        ])
      : await this.must("Uniswap mint", owner, npm, UNI_NPM, "mint", [{ ...base, fee: Number(await this.read(m.pool, POOL, "fee")) }]);
    const tokenId = this.mintedTokenId(r.receipt!, npm, owner) ?? (r.result as readonly bigint[])[0]!;
    const used = r.result as readonly bigint[];
    // PositionRef key: bytes32(tokenId) for Uniswap v3, bytes32((generation << 248) | tokenId) for Slipstream.
    const key = toHex(slip ? (BigInt(gen) << 248n) | tokenId : tokenId, { size: 32 });
    await this.must("approve the LPVault", owner, npm, NFT, "approve", [m.lpVault, tokenId]);
    return { tokenId, key, npm, ref: { integrationId: m.integrationId, positionKey: key }, amounts: [used[2]!, used[3]!] };
  }

  mintedTokenId(receipt: TransactionReceipt, npm: Address, owner: Address): bigint | undefined {
    const logs = parseEventLogs({ abi: NFT, logs: receipt.logs, eventName: "Transfer" });
    const l = logs.find((x) => eq(x.address, npm) && /^0x0+$/.test(x.args.from) && eq(x.args.to, owner));
    return l?.args.tokenId;
  }

  /** The CDP Spoke's debt reserve of the market's debt asset, from the MarketRegistry. */
  async debtReserveOf(m: Market): Promise<bigint> {
    const ids = (await this.read(this.registry, marketRegistryAbi, "getDebtReserveIds", [m.spoke])) as bigint[];
    for (const id of ids) {
      const d = await this.read(this.registry, marketRegistryAbi, "getDebtReserve", [m.spoke, id]);
      if (eq(d.asset, m.debtAsset) && d.approved) return id;
    }
    throw new StepError(`no approved ${this.sym(m.debtAsset)} debt reserve on ${m.spokeLabel}`);
  }

  /** Supplies the debt asset on the Hub's Lend Spoke when the Hub holds less than `need`. */
  async ensureLiquidity(m: Market, need: bigint): Promise<string> {
    const assetId = (await this.read(m.hub, HUB, "getAssetId", [m.debtAsset])) as bigint;
    const liquidity = (await this.read(m.hub, HUB, "getAssetLiquidity", [assetId])) as bigint;
    if (liquidity >= need) return fmt(liquidity, this.dec(m.debtAsset));
    const label = this.hubLabel(m.hub);
    const lendLabel = (this.ctx.config.aavePayload.hubs as { label: string; lendSpoke: string }[]).find((h) => h.label === label)?.lendSpoke;
    const lend = lendLabel ? (this.ctx.aave.spokes?.[lendLabel]?.proxy as Address | undefined) : undefined;
    if (!lend) throw new StepError(`no Lend Spoke for Hub ${label}`);
    const reserveId = (await this.read(lend, LEND_SPOKE, "getReserveId", [m.hub, assetId])) as bigint;
    const amount = need * 2n;
    await this.gasFor(WALLETS.lender);
    await this.mint(m.debtAsset, WALLETS.lender, amount);
    await this.approve(WALLETS.lender, m.debtAsset, lend, amount);
    await this.must("Lend Spoke supply", WALLETS.lender, lend, LEND_SPOKE, "supply", [reserveId, amount, WALLETS.lender]);
    return `${fmt(liquidity, this.dec(m.debtAsset))} + ${fmt(amount, this.dec(m.debtAsset))} supplied`;
  }

  async pledge(m: Market, owner: Address, p: Position): Promise<Account> {
    const r = await this.must("pledge", owner, this.adapter, aaveAdapterAbi, "pledge", [m.marketId, p.ref, await this.deadline()]);
    const [proxy, , credited] = r.result as readonly [Address, bigint, bigint];
    const acct = (await this.read(this.adapter, aaveAdapterAbi, "accountOf", [proxy])) as readonly [Address, bigint, Address, bigint];
    return { proxy, credited, collateralReserveId: acct[3], debtReserveId: await this.debtReserveOf(m) };
  }

  async borrow(m: Market, owner: Address, a: Account, amount: bigint, minHealthFactor: bigint) {
    const nonce = (await this.read(this.adapter, aaveAdapterAbi, "borrowNonce", [a.proxy])) as bigint;
    return this.must("borrow", owner, this.adapter, aaveAdapterAbi, "borrow", [
      m.marketId,
      a.debtReserveId,
      amount,
      owner,
      await this.deadline(),
      minHealthFactor,
      nonce,
    ]);
  }

  /** The Lens's largest borrow, or 95 % of collateral value times the collateral factor when the view fails. */
  async maxBorrow(m: Market, owner: Address, a: Account): Promise<bigint> {
    try {
      return (await this.read(this.lens, lensAbi, "previewBorrowMax", [owner, m.marketId, a.debtReserveId, await this.deadline()])) as bigint;
    } catch {
      // Fresh accounts only: no debt yet, the debt asset at $1.
      const cfBps = BigInt((this.ctx.config.listing.markets as any[]).find((x) => x.name === m.name).collateralFactorBps);
      const coll = await this.collateralUsd8(m, a);
      return (pct(pct(coll, cfBps), 9_500n) * 10n ** BigInt(this.dec(m.debtAsset))) / ONE_USD;
    }
  }

  async debt(m: Market, a: Account): Promise<bigint> {
    return (await this.read(m.spoke, aaveV4SpokeAbi, "getUserTotalDebt", [a.debtReserveId, a.proxy])) as bigint;
  }

  async supplied(m: Market, a: Account): Promise<bigint> {
    return (await this.read(m.spoke, aaveV4SpokeAbi, "getUserSuppliedAssets", [a.collateralReserveId, a.proxy])) as bigint;
  }

  async healthFactor(m: Market, a: Account): Promise<bigint> {
    return (await this.read(m.spoke, aaveV4SpokeAbi, "getUserAccountData", [a.proxy])).healthFactor as bigint;
  }

  /** Supplied vault-token units valued at the LPOracle's served price, 8 decimals. */
  async collateralUsd8(m: Market, a: Account): Promise<bigint> {
    const units = await this.supplied(m, a);
    const price = (await this.read(m.lpOracle, lpOracleAbi, "latestAnswer")) as bigint;
    return (units * price) / 10n ** BigInt(m.decimals);
  }

  /** The record of `key` in the proxy's Collateralization records (Lens). */
  async record(a: Account, key: Hex): Promise<any> {
    const recs = (await this.read(this.lens, lensAbi, "getRecords", [a.proxy, 0n, 16n])) as any[];
    const r = recs.find((x) => eq(x.positionKey, key));
    if (!r) throw new StepError(`no record ${key}`);
    return r;
  }

  /** Least token amounts for releasing `units` of a record: 90 % of the Lens's close preview, pro rata. */
  async minAmountsFor(m: Market, owner: Address, key: Hex, units: bigint, credited: bigint, p: Position): Promise<bigint[]> {
    try {
      const close = await this.read(this.lens, lensAbi, "previewCloseAccount", [owner, m.marketId, await this.deadline()]);
      const rec = (close.records as any[]).find((x) => eq(x.positionKey, key));
      if (rec && rec.units > 0n) return (rec.amounts as bigint[]).map((x) => pct((x * units) / (rec.units as bigint), 9_000n));
    } catch {
      // Fall through to the minted composition.
    }
    return p.amounts.map((x) => pct((x * units) / credited, 5_000n));
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
   * A keeper liquidation through LPVaultSwap: `Lens.previewLiquidation` sizes the call (its `params` are sent
   * unchanged), or the whole debt when the preview is not available; the keeper is funded with the debt asset,
   * approves LPVaultSwap and calls `liquidate`.
   */
  async liquidate(m: Market, a: Account, keeper: Address, label: string, full = false) {
    const dl = await this.deadline(600n);
    const debtBefore = await this.debt(m, a);
    let params: any;
    let preview: any;
    try {
      preview = await this.read(this.lens, lensAbi, "previewLiquidation", [a.proxy, a.debtReserveId, dl]);
      params = preview.params;
      this.numbers[`${label}.preview`] =
        `aaveLiquidatable ${preview.aaveLiquidatable} pricesUsable ${preview.pricesUsable} HF ${fmt(preview.healthFactor, 18)} bonusBps ${preview.bonusBps} debtToCover ${fmt(params.debtToCover, this.dec(m.debtAsset))} expectedDebtRepaid ${fmt(preview.expectedDebtRepaid, this.dec(m.debtAsset))} expectedNetPayout ${fmt(preview.expectedNetPayout, this.dec(m.debtAsset))}`;
    } catch (e) {
      this.numbers[`${label}.preview`] = `previewLiquidation failed: ${errorName(e)}`;
    }
    if (full || !params || params.debtToCover === 0n) {
      // The whole debt, plus 1 % for accrual; LPVaultSwap returns what Aave does not take in keeperOut.
      params = {
        proxy: a.proxy,
        marketId: m.marketId,
        debtReserveId: a.debtReserveId,
        debtToCover: debtBefore + debtBefore / 100n,
        routeMode: 0,
        minAmounts: [],
        deadline: dl,
        minPayout: 0n,
        maxShortfall: 0n,
      };
    }
    const funding = (params.debtToCover as bigint) + (params.maxShortfall as bigint);
    await this.gasFor(keeper);
    await this.mint(m.debtAsset, keeper, funding);
    await this.approve(keeper, m.debtAsset, this.lpVaultSwap, funding);
    const balBefore = await this.balance(m.debtAsset, keeper);
    const r = await this.ctx.send(keeper, this.lpVaultSwap, withErrors(lpVaultSwapAbi), "liquidate", [params]);
    const balAfter = await this.balance(m.debtAsset, keeper);
    const debtAfter = await this.debt(m, a);
    const d = this.dec(m.debtAsset);
    const res = r.result;
    this.numbers[`${label}.liquidate`] = r.ok
      ? `debt ${fmt(debtBefore, d)} -> ${fmt(debtAfter, d)}; repaid ${fmt(res.debtRepaid, d)} seized ${res.unitsSeized} units; keeperOut ${fmt(res.keeperOut, d)} keeperReward ${fmt(res.keeperReward, d)} avanaFee ${fmt(res.avanaFee, d)} borrowerSurplus ${fmt(res.borrowerSurplus, d)} shortfall ${fmt(res.shortfall, d)}; keeper net ${fmt(balAfter - balBefore, d)} (gas ${r.gas})`
      : `reverted: ${r.error}`;
    return { ok: r.ok, debtBefore, debtAfter, net: balAfter - balBefore, keeperOut: r.ok ? (res.keeperOut as bigint) : 0n, error: r.error };
  }

  /** The crash ratio (bps of the WETH price) that leaves health factor `targetHf` from `hf` on a full-range market. */
  static crashBpsFor(hf: bigint, targetHf: bigint, capBps: bigint): bigint {
    // Full-range LP value moves with sqrt(price): HF' = HF × sqrt(r), so r = (targetHf / HF)^2.
    const r = (targetHf * targetHf * 10_000n) / (hf * hf);
    return r < capBps ? r : capBps;
  }

  /** WETH moved to `bps` of its configured price, USDC at its configured price; every WETH market's LPOracle poked. */
  async setWeth(bps: bigint, oracles: readonly Address[]) {
    await this.refresh({ WETH: pct(this.prices.WETH!, bps), USDC: this.prices.USDC! });
    for (const o of oracles) await this.poke(o);
  }
}

/** Runs a scenario body; a StepError or any other throw becomes a fail with the numbers gathered so far. */
async function runWith(ctx: ScenarioContext, body: (e: Env) => Promise<{ ok: boolean; detail: string }>): Promise<ScenarioRun> {
  let e: Env | undefined;
  try {
    e = new Env(ctx);
    const r = await body(e);
    return { ...r, numbers: e.numbers };
  } catch (err) {
    const detail = err instanceof StepError ? err.message : (err as Error).message.split("\n")[0] ?? String(err);
    return { ok: false, detail, ...(e ? { numbers: e.numbers } : {}) };
  }
}

// ─── 1. Uniswap v3 LP: pledge, borrow GHO, fees, repay with collateral, repay, withdraw ───

async function uniswapLifecycle(e: Env) {
  const m = e.market("uni-USDC-USDT-100");
  const lp = WALLETS.uniswapLp;
  const n = e.numbers;
  n.settle = await e.settle();
  const p = await e.mintPosition(m, lp, 50_000n);
  n.position = `tokenId ${p.tokenId} key ${p.key}; minted ${fmt(p.amounts[0], e.dec(m.token0))} ${e.sym(m.token0)} + ${fmt(p.amounts[1], e.dec(m.token1))} ${e.sym(m.token1)} on [${m.tickLower}, ${m.tickUpper}]`;
  const a = await e.pledge(m, lp, p);
  n.pledge = `proxy ${a.proxy}; credited ${a.credited} units; collateral $${formatUnits(await e.collateralUsd8(m, a), 8)}`;
  const d = e.dec(m.debtAsset);
  const amount = 20_000n * 10n ** BigInt(d);
  n.liquidity = await e.ensureLiquidity(m, amount);
  const ghoBefore = await e.balance(m.debtAsset, lp);
  await e.borrow(m, lp, a, amount, 11n * 10n ** 17n);
  const ghoAfter = await e.balance(m.debtAsset, lp);
  const debt1 = await e.debt(m, a);
  n.borrow = `${fmt(amount, d)} ${e.sym(m.debtAsset)}; wallet +${fmt(ghoAfter - ghoBefore, d)}; debt ${fmt(debt1, d)}; HF ${fmt(await e.healthFactor(m, a), 18)}`;
  if (ghoAfter - ghoBefore !== amount || debt1 < amount) return { ok: false, detail: "borrow did not move the wallet and the debt by the amount" };

  // Fees: alternating swaps through the world's SwapRouter on the market's pool.
  const router = e.ctx.world.uniswapV3SwapRouter as Address;
  const fee = Number(await e.read(m.pool, POOL, "fee"));
  const s = WALLETS.swapper;
  await e.gasFor(s);
  const leg0 = e.amountForUsd(m.token0, 20_000n);
  const leg1 = e.amountForUsd(m.token1, 20_000n);
  await e.mint(m.token0, s, leg0 * 10n);
  await e.mint(m.token1, s, leg1 * 10n);
  await e.approve(s, m.token0, router, leg0 * 10n);
  await e.approve(s, m.token1, router, leg1 * 10n);
  for (let i = 0; i < 6; i++) {
    const zeroForOne = i % 2 === 0;
    await e.must("fee swap", s, router, UNI_ROUTER, "exactInputSingle", [
      {
        tokenIn: zeroForOne ? m.token0 : m.token1,
        tokenOut: zeroForOne ? m.token1 : m.token0,
        fee,
        recipient: s,
        deadline: await e.deadline(),
        amountIn: zeroForOne ? leg0 : leg1,
        amountOutMinimum: 0n,
        sqrtPriceLimitX96: 0n,
      },
    ]);
  }
  const owed = await e.read(e.lens, lensAbi, "getPositionFees", [m.marketId, p.key]).catch(() => undefined);
  const b0 = await e.balance(m.token0, lp);
  const b1 = await e.balance(m.token1, lp);
  const c = await e.must("collectFees", lp, e.adapter, aaveAdapterAbi, "collectFees", [m.marketId, p.ref, await e.deadline()]);
  const f0 = (await e.balance(m.token0, lp)) - b0;
  const f1 = (await e.balance(m.token1, lp)) - b1;
  const fees = c.result as readonly bigint[];
  n.fees = `Lens owed ${owed ? (owed.amounts as bigint[]).join("/") : "n/a"}; collected ${fmt(f0, e.dec(m.token0))} ${e.sym(m.token0)} + ${fmt(f1, e.dec(m.token1))} ${e.sym(m.token1)} (returned ${fees.join("/")})`;
  if (f0 + f1 === 0n || f0 !== fees[0] || f1 !== fees[1]) return { ok: false, detail: "collectFees paid nothing or not what it returned" };

  // Repay part of the debt with collateral, every bound filled.
  const rec = await e.record(a, p.key);
  const credited = rec.creditedAfterReconcile as bigint;
  const units = credited / 5n;
  const [debtRepaid, toWallet, hfAfter] = (await e.read(e.lens, lensAbi, "previewRepayWithCollateral", [
    lp,
    m.marketId,
    p.key,
    units,
    a.debtReserveId,
  ])) as readonly [bigint, bigint, bigint];
  const hfBefore = await e.healthFactor(m, a);
  const params = {
    marketId: m.marketId,
    position: p.ref,
    units,
    debtReserveId: a.debtReserveId,
    minAmounts: await e.minAmountsFor(m, lp, p.key, units, credited, p),
    minDebtRepaid: pct(debtRepaid, 9_900n),
    minAssetOut: pct(toWallet, 9_000n),
    deadline: await e.deadline(),
    minHealthFactor: hfBefore,
  };
  // The quote a frontend shows: the call simulated at the current block with no output bound, against the Lens
  // preview; minAssetOut is then the quote less 1 %.
  const quote = await e.ctx.client
    .simulateContract({ account: lp, address: e.adapter, abi: aaveAdapterAbi, functionName: "repayWithCollateral", args: [{ ...params, minAssetOut: 0n }] as any })
    .then((x) => x.result as readonly [bigint, bigint])
    .catch((err: Error) => { throw new Error(`repayWithCollateral quote: ${err.message.split("\n").slice(0, 2).join(" ")}`); });
  n.repayQuote = `Lens preview repaid ${fmt(debtRepaid, d)} toWallet ${fmt(toWallet, d)}; simulated repaid ${fmt(quote[0], d)} toWallet ${fmt(quote[1], d)}`;
  params.minAssetOut = pct(quote[1], 9_900n);
  const gBefore = await e.balance(m.debtAsset, lp);
  const r = await e.must("repayWithCollateral", lp, e.adapter, aaveAdapterAbi, "repayWithCollateral", [params]);
  const [repaid, assetOut] = r.result as readonly [bigint, bigint];
  const debt2 = await e.debt(m, a);
  const gAfter = await e.balance(m.debtAsset, lp);
  n.repayWithCollateral = `units ${units} of ${credited}; preview repaid ${fmt(debtRepaid, d)} toWallet ${fmt(toWallet, d)} HF ${fmt(hfAfter, 18)}; repaid ${fmt(repaid, d)} toWallet ${fmt(assetOut, d)} (minAssetOut ${fmt(params.minAssetOut, d)}, minAmounts ${params.minAmounts.join("/")}); debt ${fmt(debt1, d)} -> ${fmt(debt2, d)}; HF ${fmt(hfBefore, 18)} -> ${fmt(await e.healthFactor(m, a), 18)}`;
  if (debt2 >= debt1 || repaid < params.minDebtRepaid || assetOut < params.minAssetOut || gAfter - gBefore !== assetOut) {
    return { ok: false, detail: "repayWithCollateral did not reduce the debt within its bounds" };
  }

  // Repay the rest in full, then withdraw the record.
  const rest = await e.debt(m, a);
  const cap = rest + rest / 100n + 10n ** BigInt(d);
  await e.approve(lp, m.debtAsset, e.adapter, cap);
  const rep = await e.must("repay", lp, e.adapter, aaveAdapterAbi, "repay", [lp, m.marketId, a.debtReserveId, cap, true, await e.deadline()]);
  const debt3 = await e.debt(m, a);
  n.repay = `repayAll spent ${fmt(rep.result as bigint, d)}; debt ${fmt(rest, d)} -> ${fmt(debt3, d)}`;
  const units2 = (await e.record(a, p.key)).creditedAfterReconcile as bigint;
  await e.must("withdraw", lp, e.adapter, aaveAdapterAbi, "withdraw", [m.marketId, p.ref, units2, await e.deadline(), 0n]);
  const owner = (await e.read(p.npm, NFT, "ownerOf", [p.tokenId])) as Address;
  const left = await e.supplied(m, a);
  n.withdraw = `units ${units2}; NFT owner ${owner}; supplied units left ${left}`;
  const ok = debt3 === 0n && eq(owner, lp) && left === 0n;
  return { ok, detail: ok ? "pledge, borrow, fees, repay with collateral, repay all, withdraw" : "debt, NFT or supply not cleared" };
}

// ─── 2. Slipstream LP: pledge, borrow USDC, remove liquidity, add liquidity and recredit ───

async function slipstreamLifecycle(e: Env) {
  const m = e.market("slip-USDC-USDT-cl1");
  const lp = WALLETS.slipstreamLp;
  const n = e.numbers;
  n.settle = await e.settle();
  const p = await e.mintPosition(m, lp, 50_000n);
  n.position = `generation ${e.generation(m)} NPM ${p.npm} tokenId ${p.tokenId} key ${p.key}`;
  const a = await e.pledge(m, lp, p);
  n.pledge = `proxy ${a.proxy}; credited ${a.credited}; collateral $${formatUnits(await e.collateralUsd8(m, a), 8)}`;
  const d = e.dec(m.debtAsset);
  const amount = 15_000n * 10n ** BigInt(d);
  n.liquidity = await e.ensureLiquidity(m, amount);
  const before = await e.balance(m.debtAsset, lp);
  await e.borrow(m, lp, a, amount, 11n * 10n ** 17n);
  const got = (await e.balance(m.debtAsset, lp)) - before;
  const debt = await e.debt(m, a);
  n.borrow = `${fmt(amount, d)} ${e.sym(m.debtAsset)}; wallet +${fmt(got, d)}; debt ${fmt(debt, d)}; HF ${fmt(await e.healthFactor(m, a), 18)}`;
  if (got !== amount || debt < amount) return { ok: false, detail: "borrow did not move the wallet and the debt by the amount" };

  // Remove a fifth of the record's units; the position stays in custody.
  const credited = (await e.record(a, p.key)).creditedAfterReconcile as bigint;
  const units = credited / 5n;
  const minAmounts = await e.minAmountsFor(m, lp, p.key, units, credited, p);
  const b0 = await e.balance(m.token0, lp);
  const b1 = await e.balance(m.token1, lp);
  const supplied0 = await e.supplied(m, a);
  const r = await e.must("removeLiquidity", lp, e.adapter, aaveAdapterAbi, "removeLiquidity", [
    m.marketId,
    p.ref,
    units,
    minAmounts,
    await e.deadline(),
    105n * 10n ** 16n,
  ]);
  const out = r.result as readonly bigint[];
  const r0 = (await e.balance(m.token0, lp)) - b0;
  const r1 = (await e.balance(m.token1, lp)) - b1;
  const supplied1 = await e.supplied(m, a);
  n.removeLiquidity = `units ${units} of ${credited} (minAmounts ${minAmounts.join("/")}); paid ${fmt(r0, e.dec(m.token0))} ${e.sym(m.token0)} + ${fmt(r1, e.dec(m.token1))} ${e.sym(m.token1)}; supplied ${supplied0} -> ${supplied1}; HF ${fmt(await e.healthFactor(m, a), 18)}`;
  if (r0 !== out[0] || r1 !== out[1] || r0 + r1 === 0n || supplied0 - supplied1 !== units) {
    return { ok: false, detail: "removeLiquidity paid or burned the wrong amounts" };
  }

  // Add liquidity on the custodied position through the NPM, then recredit it.
  const add0 = e.amountForUsd(m.token0, 10_000n);
  const add1 = e.amountForUsd(m.token1, 10_000n);
  await e.mint(m.token0, lp, add0);
  await e.mint(m.token1, lp, add1);
  await e.approve(lp, m.token0, p.npm, add0);
  await e.approve(lp, m.token1, p.npm, add1);
  const inc = await e.must("increaseLiquidity", lp, p.npm, SLIP_NPM, "increaseLiquidity", [
    { tokenId: p.tokenId, amount0Desired: add0, amount1Desired: add1, amount0Min: 0n, amount1Min: 0n, deadline: await e.deadline() },
  ]);
  const preview = (await e.read(e.lens, lensAbi, "previewRecredit", [m.marketId, p.key]).catch(() => undefined)) as
    | readonly [bigint, bigint, boolean]
    | undefined;
  const rc = await e.must("recredit", lp, e.adapter, aaveAdapterAbi, "recredit", [m.marketId, p.ref, "0x", await e.deadline()]);
  const added = rc.result as bigint;
  const supplied2 = await e.supplied(m, a);
  n.recredit = `increaseLiquidity liquidity +${(inc.result as readonly bigint[])[0]}; preview added ${preview ? preview[0] : "n/a"} usdCharge ${preview ? usd8(preview[1]) : "n/a"}; added ${added}; supplied ${supplied1} -> ${supplied2}; HF ${fmt(await e.healthFactor(m, a), 18)}`;
  const ok = added > 0n && supplied2 - supplied1 === added;
  return { ok, detail: ok ? "pledge, borrow USDC, remove liquidity, add liquidity and recredit" : "recredit did not supply the added units" };
}

// ─── 3. Price paths ───

/**
 * The 1 % quote cap in one block: poke A accepts the configured price, then WETH and USDC both move down 1.5 % (their
 * ratio, and so the pool-consistency check, unchanged; the vault token's price falls 1.5 %), then poke C in the same
 * block reads Cached with QUOTE_CHANGE_CAPPED; poke D in the next block reads Live and accepts the new price. Mining
 * is paused for the block; A and C come from one sender (nonce order) and A carries the highest priority fee, C the
 * lowest, so A, the rounds and C are mined in that order under both fee and FIFO ordering.
 */
async function quoteCapBlock(e: Env, oracle: Address) {
  const w0 = e.prices.WETH!;
  const u0 = e.prices.USDC!;
  // Fresh rounds at the configured prices, not yet accepted (A accepts them).
  await e.refresh({ WETH: w0, USDC: u0 });
  const feeds = worldFeeds(e.ctx.network, ["WETH", "USDC"]);
  await e.gasFor(WALLETS.poker);
  const gwei = 1_000_000_000n;
  const poke = (tip: bigint) =>
    e.ctx.wallet.writeContract({
      account: WALLETS.poker,
      chain: null,
      address: oracle,
      abi: lpOracleAbi,
      functionName: "poke",
      gas: POKE_GAS,
      maxFeePerGas: 1_000n * gwei,
      maxPriorityFeePerGas: tip,
    } as any);
  await e.rpc("evm_setAutomine", [false]);
  let hA: Hex | undefined;
  let hC: Hex | undefined;
  const hT: Hex[] = [];
  try {
    hA = await poke(100n * gwei);
    for (const f of feeds) hT.push(await transmit(e.ctx.client, e.ctx.wallet, f.aggregator, pct(f.symbol === "WETH" ? w0 : u0, 9_850n)));
    hC = await poke(1n);
    await e.rpc("evm_mine", []);
  } finally {
    await e.rpc("evm_setAutomine", [true]);
  }
  if (!hA || !hC) throw new StepError("quote cap: the block's transactions were not sent");
  const rA = await e.ctx.client.waitForTransactionReceipt({ hash: hA });
  const rT = await Promise.all(hT.map((hash) => e.ctx.client.waitForTransactionReceipt({ hash })));
  const rC = await e.ctx.client.waitForTransactionReceipt({ hash: hC });
  const sameBlock = rT.every((r) => r.blockNumber === rA.blockNumber) && rC.blockNumber === rA.blockNumber;
  const ordered = rT.every((r) => r.transactionIndex > rA.transactionIndex && r.transactionIndex < rC.transactionIndex);
  const events = parseEventLogs({ abi: lpOracleAbi as any, logs: rC.logs }).filter((l: any) => eq(l.address, oracle)) as any[];
  const capped = events.find((l) => l.eventName === "QuoteChangeCapped");
  const changed = events.find((l) => l.eventName === "PriceStateChanged");
  // The view at the end of A's block evaluates the cap as C did (the accepted price is A's, stored in that block).
  const atBlock = await e.ctx.client
    .readContract({ address: oracle, abi: lpOracleAbi as any, functionName: "getPriceState", blockNumber: rA.blockNumber })
    .then((v: any) => e.describe(v))
    .catch((err: unknown) => `view failed: ${errorName(err)}`);
  const rD = await e.poke(oracle);
  const sD = await e.priceState(oracle);
  e.numbers["2.quoteCap"] =
    `block ${rA.blockNumber}: A ${rA.status}, ${rT.length} rounds, C ${rC.status}; sameBlock ${sameBlock} ordered ${ordered}; C QuoteChangeCapped ${capped ? `${usd8(capped.args.accepted)} -> ${usd8(capped.args.quoted)}` : "absent"}; C PriceStateChanged ${changed ? `${stateName(Number(changed.args.previous))} -> ${stateName(Number(changed.args.current))} reasons 0x${BigInt(changed.args.reasons).toString(16)}` : "none"}; view at that block: ${atBlock}`;
  e.numbers["2.quoteCap.nextBlock"] = `D ${rD.ok ? "ok" : rD.error}: ${e.describe(sD)}`;
  const ok =
    rA.status === "success" &&
    rC.status === "success" &&
    sameBlock &&
    ordered &&
    capped !== undefined &&
    (changed === undefined || (Number(changed.args.current) === CACHED && (BigInt(changed.args.reasons) & QUOTE_CHANGE_CAPPED) !== 0n)) &&
    Number(sD.state) === LIVE &&
    BigInt(sD.acceptedAnswer) === BigInt(sD.answer);
  // Back to the configured prices.
  await e.refresh({ WETH: w0, USDC: u0 });
  await e.poke(oracle);
  return ok;
}

async function pricePaths(e: Env) {
  const mw = e.market("uni-WETH-USDC-500");
  const ms = e.market("uni-USDC-USDT-100");
  const oW = mw.lpOracle;
  const oS = ms.lpOracle;
  const n = e.numbers;
  const fails: string[] = [];
  const expect = (cond: boolean, what: string) => {
    if (!cond) fails.push(what);
  };
  const w0 = e.prices.WETH!;
  const u0 = e.prices.USDC!;
  const t0 = e.prices.USDT!;
  n.settle = await e.settle();
  let s = await e.priceState(oW);
  n["0.baseline"] = `WETH market ${e.describe(s)}; stable market ${e.describe(await e.priceState(oS))}`;
  expect(Number(s.state) === LIVE, "baseline WETH market not Live");

  // 1. Slow drift: WETH down 0.2 % per step, 0.6 % in all, within the market's 100-tick pool-consistency tolerance.
  for (let k = 1n; k <= 3n; k++) {
    await e.refresh({ WETH: pct(w0, 10_000n - 20n * k), USDC: u0 });
    await e.poke(oW);
    s = await e.priceState(oW);
    n[`1.drift-${k * 20n}bps`] = e.describe(s);
    expect(Number(s.state) === LIVE && BigInt(s.acceptedAnswer) === BigInt(s.answer), `drift step ${k}: not Live or not accepted`);
  }
  await e.refresh({ WETH: w0, USDC: u0 });
  await e.poke(oW);

  // 2. The 1 % same-block quote cap.
  expect(await quoteCapBlock(e, oW), "quote cap: C not Cached with QUOTE_CHANGE_CAPPED in A's block, or D not Live in the next");

  // 3. Crashes of 30, 60 and 90 %. The pool has not followed: the oracle tick is far from the pool's 30-minute mean
  // tick, so the market is Drifting (CONSISTENCY_DEVIATION) and serves the fresh price, liquidation not paused. Once
  // the pool trades at the new price for a full TWAP window the market is Live and accepts the price.
  const pool = mw.pool;
  const startSqrt = (await e.read(pool, POOL, "slot0"))[0] as bigint;
  const d0 = e.dec(mw.token0);
  const d1 = e.dec(mw.token1);
  const ratioAt = (wethPrice: bigint) => {
    const p0 = e.sym(mw.token0) === "WETH" ? wethPrice : u0;
    const p1 = e.sym(mw.token1) === "WETH" ? wethPrice : u0;
    return sqrtPriceX96(p0, p1, d0, d1);
  };
  // The market's TWAP window (09_ListMarkets: twapWindow 1,800 s).
  const twap = 1800;
  for (const drop of [30n, 60n, 90n]) {
    const price = pct(w0, 10_000n - drop * 100n);
    await e.refresh({ WETH: price, USDC: u0 });
    await e.poke(oW);
    s = await e.priceState(oW);
    n[`3.crash-${drop}.pool-static`] = e.describe(s);
    expect(
      Number(s.state) === DRIFTING &&
        (BigInt(s.reasons) & CONSISTENCY_DEVIATION) !== 0n &&
        BigInt(s.answer) === BigInt(s.freshAnswer) &&
        !s.liquidationPaused,
      `crash ${drop} %: not Drifting on consistency at the fresh price`,
    );
    n[`3.crash-${drop}.pool`] = await e.moveUniswapPool(pool, ratioAt(price));
    await e.advance(twap + 1);
    await e.poke(oW);
    s = await e.priceState(oW);
    n[`3.crash-${drop}.pool-followed`] = e.describe(s);
    expect(Number(s.state) === LIVE && BigInt(s.acceptedAnswer) === BigInt(s.answer), `crash ${drop} %: not Live and accepted once the pool followed`);
  }
  n["3.restore.pool"] = await e.moveUniswapPool(pool, startSqrt);
  await e.advance(twap + 1);
  await e.refresh({ WETH: w0, USDC: u0 });
  await e.poke(oW);
  s = await e.priceState(oW);
  n["3.restore"] = e.describe(s);
  expect(Number(s.state) === LIVE, "WETH market not Live after the pool and price were restored");

  // 4. USDT depeg on the stable market ([-50, 50]): at $0.95 the oracle ratio is outside the range (PRICE_CLAMPED) and
  // far from the pool (Drifting), still inside the USD band (0.95 >= 0.90^2); at $0.80 it leaves the band (USD_BAND).
  for (const [label, price] of [
    ["0.95", 95_000_000n],
    ["0.80", 80_000_000n],
  ] as const) {
    await e.refresh({ USDT: price, USDC: u0 });
    await e.poke(oS);
    s = await e.priceState(oS);
    n[`4.depeg-${label}`] = `${e.describe(s)} usdLevel ${usd8(BigInt(s.usdLevel))}`;
    expect(Number(s.state) !== LIVE && (BigInt(s.reasons) & PRICE_CLAMPED) !== 0n, `USDT ${label}: not clamped or still Live`);
    if (label === "0.80") expect((BigInt(s.reasons) & USD_BAND) !== 0n, "USDT 0.80: USD_BAND not set");
    else expect((BigInt(s.reasons) & USD_BAND) === 0n, "USDT 0.95: USD_BAND set");
  }
  await e.refresh({ USDT: t0, USDC: u0 });
  await e.poke(oS);
  s = await e.priceState(oS);
  n["4.restore"] = e.describe(s);
  expect(Number(s.state) === LIVE, "stable market not Live after the depeg was restored");

  // 5. Staleness: past 88,200 s Cached, past the 3,600 s cached window Expired (latestAnswer 1), then a fresh round
  // recovers Live in grace.
  await e.refresh({ WETH: w0, USDC: u0, USDT: t0 });
  await e.poke(oW);
  await e.poke(oS);
  await e.advance(STALE_AFTER + 2);
  for (const [label, o] of [
    ["WETH", oW],
    ["stable", oS],
  ] as const) {
    await e.poke(o);
    s = await e.priceState(o);
    n[`5.stale.${label}`] = e.describe(s);
    expect(Number(s.state) === CACHED && s.liquidationPaused, `${label}: not Cached past ${STALE_AFTER} s`);
  }
  const cachedWindow = Number(e.ctx.config.parameters?.globals?.cachedWindow ?? 3600);
  await e.advance(cachedWindow);
  for (const [label, o] of [
    ["WETH", oW],
    ["stable", oS],
  ] as const) {
    await e.poke(o);
    s = await e.priceState(o);
    const answer = (await e.read(o, lpOracleAbi, "latestAnswer")) as bigint;
    n[`5.expired.${label}`] = `${e.describe(s)} latestAnswer ${answer}`;
    expect(Number(s.state) === EXPIRED && answer === 1n, `${label}: not Expired with latestAnswer 1`);
  }
  await e.refresh(e.prices, Object.keys(e.prices));
  for (const [label, o] of [
    ["WETH", oW],
    ["stable", oS],
  ] as const) {
    await e.poke(o);
    s = await e.priceState(o);
    n[`5.recovered.${label}`] = `${e.describe(s)} graceEndsAt ${s.graceEndsAt}`;
    expect(Number(s.state) === LIVE && s.inGrace && (BigInt(s.reasons) & IN_GRACE) !== 0n, `${label}: not Live in grace after the fresh round`);
  }
  // Every price back at its configured value, every oracle out of grace.
  n.restored = await e.settle(true);
  return { ok: fails.length === 0, detail: fails.length === 0 ? "drift, quote cap, crashes, depeg and staleness as documented" : fails.join("; ") };
}

// ─── 4. Keeper liquidations through LPVaultSwap ───

async function keeperLiquidations(e: Env) {
  const um = e.market("uni-WETH-USDC-500");
  const sm = e.market("slip-WETH-USDC-cl100");
  const keeper = (e.ctx.config.keepers as Address[])[0]!;
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
    await e.borrow(m, w, a, amount, WAD);
    n[`${label}.borrow`] = `${m.name}: collateral $${formatUnits(await e.collateralUsd8(m, a), 8)}; borrowed ${fmt(amount, e.dec(m.debtAsset))} ${e.sym(m.debtAsset)} of max ${fmt(max, e.dec(m.debtAsset))}; HF ${fmt(await e.healthFactor(m, a), 18)}`;
    accounts.push({ m, a, label });
  }
  // WETH falls far enough that both accounts end near HF 0.85 (full-range value moves with sqrt(price)).
  let hfMax = 0n;
  for (const x of accounts) {
    const hf = await e.healthFactor(x.m, x.a);
    if (hf > hfMax) hfMax = hf;
  }
  const bps = Env.crashBpsFor(hfMax, 85n * 10n ** 16n, 7_000n);
  await e.setWeth(bps, [um.lpOracle, sm.lpOracle]);
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
    if (!r.ok || r.debtAfter >= r.debtBefore || r.keeperOut === 0n || r.net <= 0n) {
      ok = false;
      detail.push(`${x.label}: ${r.ok ? "debt not reduced or keeper not paid" : r.error}`);
    }
  }
  n.restored = await e.settle();
  return { ok, detail: ok ? `keeper ${keeper} liquidated on ${um.name} (GHO) and ${sm.name} (USDC)` : detail.join("; ") };
}

// ─── 5. Self-liquidation attempt ───

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
  await e.borrow(m, b, a, amount, WAD);
  const d = e.dec(m.debtAsset);
  const cover = 1_000n * 10n ** BigInt(d);
  await e.mint(m.debtAsset, b, cover);
  await e.approve(b, m.debtAsset, e.lpVaultSwap, cover);
  await e.approve(b, m.debtAsset, m.spoke, cover);
  const params = async () => ({
    proxy: a.proxy,
    marketId: m.marketId,
    debtReserveId: a.debtReserveId,
    debtToCover: cover,
    routeMode: 0,
    minAmounts: [],
    deadline: await e.deadline(600n),
    minPayout: 0n,
    maxShortfall: 0n,
  });

  // (1) Healthy account: the borrower's own LPVaultSwap.liquidate.
  const hf1 = await e.healthFactor(m, a);
  const r1 = await e.tryCall(b, e.lpVaultSwap, lpVaultSwapAbi, "liquidate", [await params()]);
  n["1.healthy.LPVaultSwap.liquidate"] = `HF ${fmt(hf1, 18)}: ${r1.reverted ? `reverted ${r1.name}` : "SUCCEEDED"}`;

  // (2) Underwater account: the borrower calls the CDP Spoke's liquidationCall on its own proxy directly.
  const bps = Env.crashBpsFor(hf1, 85n * 10n ** 16n, 7_000n);
  await e.setWeth(bps, [m.lpOracle]);
  const hf2 = await e.healthFactor(m, a);
  const r2 = await e.tryCall(b, m.spoke, aaveV4SpokeAbi, "liquidationCall", [a.collateralReserveId, a.debtReserveId, a.proxy, cover, false]);
  n["2.underwater.Spoke.liquidationCall"] = `WETH at ${bps} bps, HF ${fmt(hf2, 18)}: ${r2.reverted ? `reverted ${r2.name}` : "SUCCEEDED"}`;

  // (3) Recorded, not asserted: the borrower's own LPVaultSwap.liquidate while underwater (simulated only).
  const r3 = await e.tryCall(b, e.lpVaultSwap, lpVaultSwapAbi, "liquidate", [await params()]);
  n["3.underwater.LPVaultSwap.liquidate (simulated)"] = r3.reverted
    ? `reverted ${r3.name}`
    : `would succeed: repaid ${fmt(r3.result.debtRepaid, d)}, keeperOut ${fmt(r3.result.keeperOut, d)}, borrowerSurplus ${fmt(r3.result.borrowerSurplus, d)}`;
  n.restored = await e.settle();
  const ok = r1.reverted && r2.reverted && hf2 < WAD;
  return {
    ok,
    detail: ok
      ? `own-proxy liquidation refused: LPVaultSwap ${r1.name}; Spoke ${r2.name}`
      : `${r1.reverted ? "" : "healthy LPVaultSwap.liquidate succeeded; "}${r2.reverted ? "" : "direct Spoke.liquidationCall succeeded; "}${hf2 < WAD ? "" : "HF not below 1 after the crash"}`,
  };
}

// ─── 6. Deficit after a 90 % crash, covered by the First-Loss Reserve ───

async function deficitCoverage(e: Env) {
  const m = e.market("uni-WETH-USDC-500");
  const b = WALLETS.deficitBorrower;
  const keeper = (e.ctx.config.keepers as Address[])[0]!;
  const guardian = e.ctx.actors.emergencyGuardian!;
  const n = e.numbers;
  n.settle = await e.settle();
  const p = await e.mintPosition(m, b, 50_000n);
  const a = await e.pledge(m, b, p);
  const max = await e.maxBorrow(m, b, a);
  const amount = pct(max, 9_900n);
  n.liquidity = await e.ensureLiquidity(m, amount);
  await e.borrow(m, b, a, amount, WAD);
  const d = e.dec(m.debtAsset);
  const coll = await e.collateralUsd8(m, a);
  const debt = await e.debt(m, a);
  const debtUsd = (debt * ONE_USD) / 10n ** BigInt(d);
  // A deficit needs collateral below debt times the liquidation bonus. Full-range value moves with sqrt(price): a
  // 90 % crash leaves sqrt(0.1) = 31.6 % of the value; a deeper one is used when that still covers debt × bonus × 0.95.
  const target = (debtUsd * m.maxLiquidationBonus * 9_500n) / (10_000n * 10_000n);
  const r = (target * target * 10_000n) / (coll * coll);
  const bps = r < 1_000n ? r : 1_000n;
  n.position = `collateral ${usd8(coll)} debt ${fmt(debt, d)} ${e.sym(m.debtAsset)} HF ${fmt(await e.healthFactor(m, a), 18)}; crash to ${bps} bps (${10_000n - bps} bps down)`;
  await e.setWeth(bps, [m.lpOracle]);
  const after = await e.collateralUsd8(m, a);
  n.crash = `collateral ${usd8(after)} vs debt ${usd8(debtUsd)}; HF ${fmt(await e.healthFactor(m, a), 18)}`;

  const hubAbi = withErrors(aaveV4HubAbi);
  const assetId = (await e.read(m.hub, hubAbi, "getAssetId", [m.debtAsset])) as bigint;
  const defBefore = (await e.read(m.hub, hubAbi, "getSpokeDeficitRay", [assetId, m.spoke])) as bigint;
  const assetDefBefore = (await e.read(m.hub, hubAbi, "getAssetDeficitRay", [assetId])) as bigint;
  const liq = await e.liquidate(m, a, keeper, "liquidation", true);
  const defAfter = (await e.read(m.hub, hubAbi, "getSpokeDeficitRay", [assetId, m.spoke])) as bigint;
  const left = await e.supplied(m, a);
  n.deficit = `Spoke deficit ${fmt(defBefore, 27 + d)} -> ${fmt(defAfter, 27 + d)} ${e.sym(m.debtAsset)}; Hub asset deficit before ${fmt(assetDefBefore, 27 + d)}; proxy debt ${fmt(liq.debtAfter, d)} supplied units ${left}`;
  if (!liq.ok || defAfter <= defBefore) {
    n.restored = await e.settle();
    return { ok: false, detail: liq.ok ? "no deficit recorded on the CDP Spoke" : `liquidation reverted: ${liq.error}` };
  }

  // The First-Loss Reserve of (Hub, asset) covers the deficit.
  const coverage = e.ctx.file("coverage.json") ?? {};
  const key = `AvanaFirstLossReserve.${e.hubLabel(m.hub)}.${e.sym(m.debtAsset)}`;
  const cs = coverage[key] as Address | undefined;
  if (!cs) throw new StepError(`no ${key} in coverage.json`);
  const registered = (await e.read(e.registry, marketRegistryAbi, "firstLossReserveOf", [m.hub, m.debtAsset])) as Address;
  const allowed = (await e.read(cs, firstLossReserveAbi, "allowedBorrowSpoke", [m.spoke])) as boolean;
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
  await e.gasFor(guardian);
  // The funded balance earns the Hub's supply interest from block to block, so the check is on the First-Loss Reserve's
  // Hub shares, which do not accrue: they fall by exactly the shares `coverDeficit` reports, and the deficit is gone.
  const shares0 = (await e.read(cs, firstLossReserveAbi, "fundedShares")) as bigint;
  const c = await e.ctx.send(guardian, cs, withErrors(firstLossReserveAbi), "coverDeficit", [m.spoke, maxUint256]);
  const defFinal = (await e.read(m.hub, hubAbi, "getSpokeDeficitRay", [assetId, m.spoke])) as bigint;
  const funded1 = (await e.read(cs, firstLossReserveAbi, "fundedBalance")) as bigint;
  const shares1 = (await e.read(cs, firstLossReserveAbi, "fundedShares")) as bigint;
  // From the mined DeficitCovered event: the simulated return is priced at the previous block's timestamp.
  const ev = c.ok
    ? (parseEventLogs({ abi: firstLossReserveAbi as any, logs: c.receipt!.logs, eventName: "DeficitCovered" }).find((l: any) => eq(l.address, cs)) as any)
    : undefined;
  const [burned, covered]: readonly [bigint, bigint] = ev ? [ev.args.sharesBurned as bigint, ev.args.covered as bigint] : [0n, 0n];
  n.coverage = `${key} ${cs} (registry ${eq(registered, cs) ? "agrees" : registered}); allowlisted ${allowed}; top-up ${fmt(topUp, d)}; coverDeficit by Emergency Guardian ${c.ok ? `covered ${fmt(covered, d)} for ${burned} shares` : c.error}; deficit ${fmt(defAfter, 27 + d)} -> ${fmt(defFinal, 27 + d)}; funded ${fmt(funded0, d)} -> ${fmt(funded1, d)}; shares ${shares0} -> ${shares1}`;
  n.restored = await e.settle();
  const ok = c.ok && ev !== undefined && defFinal === 0n && covered === (defAfter + RAY - 1n) / RAY && burned > 0n && shares0 - shares1 === burned;
  return { ok, detail: ok ? `deficit of ${fmt(covered, d)} ${e.sym(m.debtAsset)} covered by ${key}, ${burned} Hub shares burned` : "deficit not fully covered, or the First-Loss Reserve's shares did not fall by the shares burned" };
}

// ─── 7. Cross-Hub credit line (off at launch) ───

async function crossHubLine(e: Env) {
  const m = e.market("uni-USDC-USDT-100");
  const n = e.numbers;
  const gho = e.token("GHO");
  const hubs = e.ctx.manifest.aave.hubs as { address: Address; label: string }[];
  let fundingHub: Address | undefined;
  for (const h of hubs) {
    if (eq(h.address, m.hub)) continue;
    const tier = Number(await e.read(e.registry, marketRegistryAbi, "hubTier", [h.address]));
    if (tier !== 0 && (!fundingHub || h.label === "volatile")) fundingHub = h.address;
  }
  if (!fundingHub) throw new StepError("no second recorded Hub");
  const enabled = (await e.read(e.registry, marketRegistryAbi, "crossHubLinesEnabled")) as boolean;
  const admin = (await e.read(e.registry, marketRegistryAbi, "hasRole", [keccak256(stringToBytes("APPLICATION_ADMIN")), e.timelock])) as boolean;
  const r1 = await e.tryCall(e.timelock, e.registry, marketRegistryAbi, "setCrossHubLine", [fundingHub, gho, m.spoke, 1_000_000n * WAD]);
  // A cross-Hub GHO debt reserve on the stable CDP Spoke funded by the other Hub, at an unused reserve ID.
  const reserveId = (await e.read(m.spoke, aaveV4SpokeAbi, "getReserveCount")) as bigint;
  const homeGho = await e.debtReserveOf(m).catch(() => undefined);
  const homeDef = homeGho === undefined ? undefined : await e.read(e.registry, marketRegistryAbi, "getDebtReserve", [m.spoke, homeGho]);
  const def = {
    reserveId,
    asset: gho,
    decimals: 18,
    fundingHub,
    hubAssetId: (await e.read(fundingHub, HUB, "getAssetId", [gho]).catch(() => 0n)) as bigint,
    priceSource: (homeDef?.priceSource ?? e.ctx.world.feeds?.GHO?.primary) as Address,
    fixedPrice: true,
    firstLossReserve: (await e.read(e.registry, marketRegistryAbi, "firstLossReserveOf", [fundingHub, gho])) as Address,
    crossHub: true,
    approved: true,
  };
  const r2 = await e.tryCall(e.timelock, e.registry, marketRegistryAbi, "enableDebtReserve", [m.spoke, def]);
  n.switch = `crossHubLinesEnabled ${enabled}; timelock holds APPLICATION_ADMIN ${admin}`;
  n.setCrossHubLine = `(funding Hub ${fundingHub}, GHO, ${m.spokeLabel}, 1,000,000 GHO) as timelock: ${r1.reverted ? `reverted ${r1.name}` : "SUCCEEDED"}`;
  n.enableDebtReserve = `cross-Hub GHO reserve ${reserveId} on ${m.spokeLabel} as timelock: ${r2.reverted ? `reverted ${r2.name}` : "SUCCEEDED"}`;
  const ok = !enabled && admin && r1.name.startsWith("CrossHubLinesDisabled") && r2.name.startsWith("CrossHubLinesDisabled");
  return { ok, detail: ok ? "cross-Hub line and cross-Hub debt reserve refused with CrossHubLinesDisabled" : "a cross-Hub call was not refused with CrossHubLinesDisabled" };
}

// ─── Export ───

export function marketScenarios(ctx: ScenarioContext): Scenario[] {
  const s = (name: string, body: (e: Env) => Promise<{ ok: boolean; detail: string }>): Scenario => ({
    name,
    needs: "market",
    run: () => runWith(ctx, body),
  });
  return [
    s("LP pledges a Uniswap v3 position, borrows GHO, collects fees, repays and withdraws", uniswapLifecycle),
    s("LP pledges a Slipstream position, borrows USDC, removes liquidity, adds collateral", slipstreamLifecycle),
    s("price paths: slow drift, 30/60/90 % crashes, depeg, feed staleness", pricePaths),
    s("keeper liquidates through LPVaultSwap on a Uniswap pool and on a Slipstream pool", keeperLiquidations),
    s("self-liquidation attempt by the borrower", selfLiquidation),
    s("deficit after a 90 % crash and First-Loss Reserve coverage", deficitCoverage),
    s("cross-Hub credit line borrow (off at launch: must revert)", crossHubLine),
  ];
}
