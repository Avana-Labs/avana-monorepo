// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The market-activity loop of one local chain: simulated lenders, borrowers and traders act on every listed market so
// rates, utilisation, volumes, fees and charts move as on a live market (as the sandbox's simulation does), on real
// contracts. Each tick (30 s on the local Ethereum, 10 s on the local Base) does one action, picked at random:
//   lend      a lender supplies a Hub asset on its Lend Spoke, or withdraws part of what it supplied
//   borrow    a borrower mints a liquidity position of a market, pledges it and borrows 30-60 % of its borrow power
//   repay     a borrower repays 20-100 % of its debt
//   swap      a trader swaps on a market's Uniswap v3 pool and back (volume and fees, the price returns)
//   price     a volatile token's price moves (at most 0.4 % a step, 4 % from its listed price): its feeds publish it
//             and the listed Uniswap v3 pools holding it follow
// Every 20 minutes every feed publishes a fresh round (a Chainlink heartbeat), so the oracles stay live.
//
// The simulated users are fixed addresses with no key, sending through anvil's unlocked senders, and gas comes from
// anvil_setBalance. Their tokens come from the `activity-funds` keystore, which the stack funds once from the token
// minter; nothing here signs as the deployer. The loop pauses while STACK/activity.paused exists (the
// stack's checks hold the chains still).
//
// Usage, from contracts/:  node script/local/activity.ts --chain ethereum|base [--once]

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { type Address, createWalletClient, erc20Abi, http, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { decryptKeystore } from "../../../services/keeper/src/adapters/localKeystore.ts";
import { STACK, chainOf, rpcUrl } from "./lib/env.ts";
import { currentConfig, refreshFeeds, stepEnv } from "./lib/chain.ts";
import { PASSWORD_FILE, keystorePath } from "./lib/keys.ts";

const ci = process.argv.indexOf("--chain");
const chain = chainOf(ci === -1 ? "ethereum" : process.argv[ci + 1]!);
// The scenario modules read their chain from these at import.
process.env.RPC_ANVIL = rpcUrl(chain);
process.env.AVANA_CONFIG = currentConfig(chain).slice(currentConfig(chain).indexOf("deployments-local")).split("\\").join("/");
process.argv.push("--network", chain.network);
Object.assign(process.env, stepEnv(chain));

const { ctx } = await import("../e2e/scenarios/context.ts");
const { Env } = await import("../e2e/scenarios/market.ts");
const { aaveAdapterAbi } = await import("@avana/protocol/abis");

type Market = InstanceType<typeof Env>["markets"][number];
const log = (o: Record<string, unknown>) => process.stdout.write(`${JSON.stringify({ t: new Date().toISOString(), chain: chain.network, ...o }, (_, v) => (typeof v === "bigint" ? v.toString() : v))}\n`);

// ─── The treasury: tokens for the simulated users ───

const password = readFileSync(PASSWORD_FILE, "utf8").trim();
const treasury = privateKeyToAccount(await decryptKeystore(readFileSync(keystorePath("activity-funds"), "utf8"), password));
const treasuryWallet = createWalletClient({ account: treasury, transport: http(rpcUrl(chain)) });

class ActivityEnv extends Env {
  /** Simulated users get tokens from the treasury, not from the token's minter. */
  override async mint(token: Address, to: Address, amount: bigint) {
    const hash = await treasuryWallet.writeContract({ address: token, abi: erc20Abi, functionName: "transfer", args: [to, amount], chain: null });
    const r = await ctx.client.waitForTransactionReceipt({ hash });
    if (r.status !== "success") throw new Error(`treasury transfer of ${amount} ${this.sym(token)} reverted`);
  }
}
const e = new ActivityEnv(ctx);

// ─── State: who holds what ───

interface Borrower { owner: Address; market: string; proxy: Address; debtReserveId: string }
interface Lender { owner: Address; lendSpoke: Address; reserveId: string; token: Address }
const STATE = join(STACK, `activity-${chain.key}.json`);
const state: { n: number; borrowers: Borrower[]; lenders: Lender[] } = existsSync(STATE) ? JSON.parse(readFileSync(STATE, "utf8")) : { n: 0, borrowers: [], lenders: [] };
const save = () => writeFileSync(STATE, `${JSON.stringify(state, null, 2)}\n`);
/** A fresh simulated user: a fixed address pattern with no key (0x5157…<n>). */
const nextUser = (): Address => {
  state.n += 1;
  return `0x5157${chain.chainId.toString(16).padStart(8, "0")}${state.n.toString(16).padStart(28, "0")}` as Address;
};

const rand = (lo: number, hi: number) => lo + Math.random() * (hi - lo);
const pick = <T>(xs: readonly T[]): T => xs[Math.floor(Math.random() * xs.length)]!;
const usd = (lo: number, hi: number) => BigInt(Math.round(rand(lo, hi)));
const isUniswap = (m: Market) => !e.isSlipstream(m);

const { aaveV4SpokeAbi: LEND } = await import("@avana/protocol/abis");
const ROUTER = parseAbi([
  "struct ExactInputSingleParams { address tokenIn; address tokenOut; uint24 fee; address recipient; uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96; }",
  "function exactInputSingle(ExactInputSingleParams params) payable returns (uint256 amountOut)",
]);
const POOL = parseAbi(["function fee() view returns (uint24)"]);

/** Every Lend Spoke reserve of the manifest's Lend Spokes. */
async function lendReserves(): Promise<{ lendSpoke: Address; reserveId: bigint; token: Address }[]> {
  const out: { lendSpoke: Address; reserveId: bigint; token: Address }[] = [];
  for (const s of ctx.manifest.aave.lendSpokes as { address: Address }[]) {
    const n = (await e.read(s.address, LEND, "getReserveCount")) as bigint;
    for (let i = 0n; i < n; i++) {
      const r = (await e.read(s.address, LEND, "getReserve", [i])) as { underlying: Address };
      if (e.symbolOf[r.underlying.toLowerCase()]) out.push({ lendSpoke: s.address, reserveId: i, token: r.underlying });
    }
  }
  return out;
}
const reserves = await lendReserves().catch((err: Error) => {
  log({ msg: "lend reserves unreadable", error: err.message.slice(0, 300) });
  return [];
});

// ─── Actions ───

async function lend(): Promise<string> {
  const withdraw = state.lenders.length > 3 && Math.random() < 0.35;
  if (withdraw) {
    const l = pick(state.lenders);
    const has = (await e.read(l.lendSpoke, LEND, "getUserSuppliedAssets", [BigInt(l.reserveId), l.owner])) as bigint;
    if (has === 0n) return "nothing to withdraw";
    const amount = (has * BigInt(Math.round(rand(10, 60)))) / 100n;
    await e.must("Lend Spoke withdraw", l.owner, l.lendSpoke, LEND, "withdraw", [BigInt(l.reserveId), amount, l.owner]);
    return `withdrew ${amount} ${e.sym(l.token)}`;
  }
  const r = pick(reserves);
  const owner = state.lenders.length < 40 || Math.random() < 0.3 ? nextUser() : pick(state.lenders).owner;
  const amount = e.amountForUsd(r.token, usd(5_000, 250_000));
  await e.gasFor(owner);
  await e.mint(r.token, owner, amount);
  await e.approve(owner, r.token, r.lendSpoke, amount);
  await e.must("Lend Spoke supply", owner, r.lendSpoke, LEND, "supply", [r.reserveId, amount, owner]);
  if (!state.lenders.some((x) => x.owner === owner && x.reserveId === String(r.reserveId) && x.lendSpoke === r.lendSpoke)) state.lenders.push({ owner, lendSpoke: r.lendSpoke, reserveId: String(r.reserveId), token: r.token });
  return `supplied ${amount} ${e.sym(r.token)}`;
}

async function borrow(): Promise<string> {
  const m = pick(e.markets);
  const owner = nextUser();
  await e.gasFor(owner);
  const p = await e.mintPosition(m, owner, usd(5_000, 60_000));
  const a = await e.pledge(m, owner, p);
  const max = await e.maxBorrow(m, owner, a);
  const amount = (max * BigInt(Math.round(rand(30, 60)))) / 100n;
  if (amount === 0n) return `pledged on ${m.name}, nothing to borrow`;
  await e.ensureLiquidity(m, amount);
  await e.borrow(m, owner, a, amount, 1_050_000_000_000_000_000n);
  state.borrowers.push({ owner, market: m.name, proxy: a.proxy, debtReserveId: String(a.debtReserveId) });
  return `pledged on ${m.name} and borrowed ${amount} ${e.sym(m.debtAsset)}`;
}

async function repay(): Promise<string> {
  if (state.borrowers.length === 0) return borrow();
  const b = pick(state.borrowers);
  const m = e.market(b.market);
  const a = { proxy: b.proxy, debtReserveId: BigInt(b.debtReserveId) } as Parameters<typeof e.debt>[1];
  const debt = await e.debt(m, a);
  if (debt === 0n) {
    state.borrowers = state.borrowers.filter((x) => x !== b);
    return `${b.owner} has no debt left`;
  }
  const all = Math.random() < 0.25;
  const amount = all ? debt + debt / 100n + 10n ** BigInt(e.dec(m.debtAsset)) : (debt * BigInt(Math.round(rand(20, 80)))) / 100n;
  await e.gasFor(b.owner);
  await e.mint(m.debtAsset, b.owner, amount);
  await e.approve(b.owner, m.debtAsset, e.adapter, amount);
  await e.must("repay", b.owner, e.adapter, aaveAdapterAbi, "repay", [b.owner, m.marketId, a.debtReserveId, amount, all, await e.deadline()]);
  if (all) state.borrowers = state.borrowers.filter((x) => x !== b);
  return `${all ? "repaid all of" : "repaid"} ${all ? debt : amount} ${e.sym(m.debtAsset)} on ${m.name}`;
}

/** A swap on a market's pool and the swap back: volume and fees, the price returns to about where it was. */
async function swap(): Promise<string> {
  const uni = e.markets.filter(isUniswap);
  if (uni.length === 0) return "no Uniswap v3 market";
  const m = pick(uni);
  const router = ctx.world.uniswapV3SwapRouter as Address;
  const trader = nextUser();
  const fee = Number(await e.read(m.pool, POOL, "fee"));
  const [a, b] = Math.random() < 0.5 ? [m.token0, m.token1] : [m.token1, m.token0];
  const amountIn = e.amountForUsd(a, usd(1_000, 80_000));
  await e.gasFor(trader);
  await e.mint(a, trader, amountIn);
  await e.approve(trader, a, router, amountIn);
  const r1 = await e.must("swap", trader, router, ROUTER, "exactInputSingle", [{ tokenIn: a, tokenOut: b, fee, recipient: trader, deadline: await e.deadline(), amountIn, amountOutMinimum: 0n, sqrtPriceLimitX96: 0n }]);
  const out = r1.result as bigint;
  await e.approve(trader, b, router, out);
  await e.must("swap back", trader, router, ROUTER, "exactInputSingle", [{ tokenIn: b, tokenOut: a, fee, recipient: trader, deadline: await e.deadline(), amountIn: out, amountOutMinimum: 0n, sqrtPriceLimitX96: 0n }]);
  return `swapped ${amountIn} ${e.sym(a)} for ${out} ${e.sym(b)} and back on ${m.name}`;
}

/**
 * A price move of one non-stable token: at most 0.4 % a step and 4 % from its listed price. Its four feeds publish the
 * new price and each listed market's Uniswap v3 pool holding it is moved to the feeds' ratio, so pools and feeds stay
 * within every market's consistency tolerance.
 */
const BASE_PRICES = { ...e.prices };
async function price(): Promise<string> {
  const pooled = new Set(e.markets.filter(isUniswap).flatMap((m) => [e.sym(m.token0), e.sym(m.token1)]));
  const stable = new Set((ctx.config.listing.tokens as { symbol: string; isUsdStable: boolean }[]).filter((t) => t.isUsdStable).map((t) => t.symbol));
  const movable = [...pooled].filter((s) => !stable.has(s) && !/USD|DAI|GHO/.test(s) && BASE_PRICES[s] !== undefined);
  if (movable.length === 0) return "no volatile token in a listed Uniswap v3 market";
  const sym = pick(movable);
  const base = BASE_PRICES[sym]!;
  const step = BigInt(Math.round(rand(-40, 40)));
  let next = (e.prices[sym]! * (10_000n + step)) / 10_000n;
  const lo = (base * 9_600n) / 10_000n;
  const hi = (base * 10_400n) / 10_000n;
  next = next < lo ? lo : next > hi ? hi : next;
  e.prices[sym] = next;
  await e.refresh({ [sym]: next }, [sym]);
  const moved: string[] = [];
  for (const m of e.markets.filter(isUniswap).filter((x) => e.sym(x.token0) === sym || e.sym(x.token1) === sym)) {
    const [s0, s1] = [e.sym(m.token0), e.sym(m.token1)];
    const target = sqrtPriceX96(e.prices[s0]!, e.prices[s1]!, e.dec(m.token0), e.dec(m.token1));
    await e.moveUniswapPool(m.pool, target);
    moved.push(m.name);
  }
  return `${sym} ${base} -> ${next} (${step >= 0n ? "+" : ""}${Number(step) / 100}%); pools ${moved.join(", ") || "none"}`;
}

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
const sqrtPriceX96 = (p0: bigint, p1: bigint, d0: number, d1: number) => isqrt((p0 * 10n ** BigInt(d1) * (1n << 192n)) / (p1 * 10n ** BigInt(d0)));

// ─── The loop ───

const ACTIONS: [string, number, () => Promise<string>][] = [
  ["lend", 0.27, lend],
  ["borrow", 0.18, borrow],
  ["repay", 0.15, repay],
  ["swap", 0.3, swap],
  ["price", 0.1, price],
];
const choose = () => {
  let x = Math.random();
  for (const a of ACTIONS) if ((x -= a[1]) <= 0) return a;
  return ACTIONS[0]!;
};

const TICK_MS = (chain.blockTime >= 12 ? 30 : 10) * 1000;
const HEARTBEAT_MS = 20 * 60 * 1000;
let lastHeartbeat = 0;
const once = process.argv.includes("--once");
log({ msg: "activity", markets: e.markets.map((m) => m.name), lendReserves: reserves.length, treasury: treasury.address });

for (;;) {
  if (existsSync(join(STACK, "activity.paused"))) {
    await new Promise((r) => setTimeout(r, 5_000));
    continue;
  }
  if (Date.now() - lastHeartbeat > HEARTBEAT_MS) {
    try {
      refreshFeeds(chain, { ...process.env }, join(STACK, "logs", `activity-${chain.key}-feeds.log`));
      lastHeartbeat = Date.now();
      log({ action: "heartbeat", detail: "every feed published a fresh round" });
    } catch (err) {
      log({ action: "heartbeat", error: (err as Error).message.slice(0, 300) });
    }
  }
  const [name, , fn] = once ? ACTIONS[0]! : choose();
  const t0 = Date.now();
  try {
    const detail = await fn();
    save();
    log({ action: name, detail, ms: Date.now() - t0 });
  } catch (err) {
    log({ action: name, error: (err as Error).message.split("\n").slice(0, 2).join(" ").slice(0, 400), ms: Date.now() - t0 });
  }
  if (once) break;
  await new Promise((r) => setTimeout(r, Math.max(1_000, TICK_MS - (Date.now() - t0))));
}
