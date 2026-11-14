// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Rehearsals 09 (going backward and emergencies) and 10 (interest rates) of the local rehearsal: each drill applies its
// forward change through the named step `11-changes <file>` (script/deploy/changes.ts; the files are in
// script/e2e/drills/), checks on chain that it took effect (a borrow or pledge refused with the expected error, while
// repay stays open), applies the backward change and checks that the action works again. A drill whose forward change
// is permanent by design (offboarding, closing a market, retiring a Spoke) runs inside an anvil snapshot and reverts it
// afterwards, so the deployment the manifest describes is the one the later steps see; its backward part is the part
// the protocol allows (an Aave unfreeze, a debt reserve enabled again), and the detail says what stays one-way.
//
// Usage, from contracts/ on a rehearsal chain (after the manifest step):
//   node script/e2e/drills.ts --network anvil --drill <name>      names: setup and the DRILLS keys below
// Exit status: 0 pass, 1 fail, 3 not run (the reason is the last line). Each drill also writes
// deployments-local/<network>/drills/<name>.json with its checks.

import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { request } from "node:https";
import { tmpdir } from "node:os";
import { isAbsolute, join } from "node:path";
import { type Address, type Hex, maxUint256, parseAbi } from "viem";
import {
  aaveAdapterAbi,
  aaveV4HubAbi,
  aaveV4SpokeAbi,
  firstLossReserveAbi,
  marketRegistryAbi,
  parameterStoreAbi,
} from "../../../packages/protocol/src/abis/index.ts";
import { blockingReason, effectiveMode, type SafetyState } from "../../../services/keeper/src/safety/guards.ts";
import { readHalt, startKillSwitch } from "../../../services/keeper/src/safety/killSwitch.ts";
import { CONTRACTS, arg, ctx, out, rpc } from "./scenarios/context.ts";
import { type Account, Env, type Market, type Position, StepError } from "./scenarios/market.ts";
import { transmit } from "./scenarios/ocr2.ts";

const DIR = join(CONTRACTS, "script/e2e/drills");
const RECORDS = join(out, "drills");
const STATE = join(RECORDS, "state.json");
const WAD = 10n ** 18n;
const RATE_ABI = parseAbi([
  "function getInterestRateData(uint256 assetId) view returns ((uint16 optimalUsageRatio, uint32 baseDrawnRate, uint32 rateGrowthBeforeOptimal, uint32 rateGrowthAfterOptimal))",
]);

/** Drill wallets; the scenario wallets (0x…0c0n) stay untouched for the scenarios that run later. */
const W = {
  borrower: "0x1000000000000000000000000000000000000d01",
  pledger: "0x1000000000000000000000000000000000000d02",
  volBorrower: "0x1000000000000000000000000000000000000d03",
  slipBorrower: "0x1000000000000000000000000000000000000d04",
  deficit: "0x1000000000000000000000000000000000000d06",
  anyone: "0x1000000000000000000000000000000000000d0f",
} as const satisfies Record<string, Address>;

const M1 = "uni-USDC-USDT-100";
const M2 = "uni-WETH-USDC-500";
const M4 = "slip-WETH-USDC-cl100";
const M6 = "uni-USDC-USDT-500-growth";

class NotRun extends Error {}

// ─── State shared by the drills (written by setup) ───

interface Holder {
  readonly market: string;
  readonly owner: Address;
  readonly account: Account;
  readonly position: Position;
}
interface State {
  borrower: Holder;
  volBorrower: Holder;
  slipBorrower: Holder;
  pledger: { readonly market: string; readonly owner: Address; readonly position: Position };
}

const big = (_k: string, v: unknown) => (typeof v === "bigint" ? { $big: v.toString() } : v);
const unbig = (_k: string, v: any) => (v && typeof v === "object" && "$big" in v ? BigInt(v.$big) : v);
const loadState = (): State => {
  if (!existsSync(STATE)) throw new NotRun("drill setup has not run (drills/state.json)");
  return JSON.parse(readFileSync(STATE, "utf8"), unbig) as State;
};

// ─── Changes files through the named step ───

interface StepRun {
  readonly code: number;
  readonly text: string;
}

/** Runs `script/deploy/step.sh 11-changes <drills/file>`; the full output goes to the drill's log. */
function changes(file: string, log: string[]): StepRun {
  const path = isAbsolute(file) ? file : join(DIR, file);
  const r = spawnSync("bash", ["script/deploy/step.sh", "11-changes", path], {
    cwd: CONTRACTS,
    env: { ...process.env, AVANA_NETWORK: ctx.network, AVANA_RPC_URL: rpc },
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  const text = `${r.stdout ?? ""}${r.stderr ?? ""}`.trim();
  log.push(`$ step.sh 11-changes ${isAbsolute(file) ? file : `script/e2e/drills/${file}`} -> exit ${r.status}`, ...text.split("\n").map((l) => `    ${l}`));
  return { code: r.status ?? 1, text };
}

function mustApply(file: string, log: string[]) {
  const r = changes(file, log);
  if (r.code !== 0) throw new StepError(`11-changes ${file} exited ${r.code}: ${r.text.split("\n").slice(-3).join(" ")}`);
}

/** Runs a deploy step (step.sh), for the drills that replay part of a release. */
function deployStep(step: string, log: string[], env: Record<string, string> = {}) {
  const r = spawnSync("bash", ["script/deploy/step.sh", step], {
    cwd: CONTRACTS,
    env: { ...process.env, AVANA_NETWORK: ctx.network, AVANA_RPC_URL: rpc, AVANA_DEPLOYER: ctx.actors.deployer!, ...env },
    encoding: "utf8",
    maxBuffer: 256 * 1024 * 1024,
  });
  const text = `${r.stdout ?? ""}${r.stderr ?? ""}`;
  const lines = text.split("\n").filter((l) => /Error|revert|executed|scheduled|listed|nothing|BLOCKED|output|LPOracle|market/.test(l)).slice(0, 12);
  log.push(`$ step.sh ${step} -> exit ${r.status}`, ...lines.map((l) => `    ${l.trim()}`));
  return { code: r.status ?? 1, text };
}

// ─── Probes: what a user can do right now ───

interface Probe {
  readonly ok: boolean;
  readonly error: string;
}

async function tryAs(e: Env, from: Address, abi: readonly unknown[], fn: string, args: readonly unknown[], to: Address = e.adapter): Promise<Probe> {
  await e.gasFor(from);
  const r = await e.tryCall(from, to, abi, fn, args);
  return { ok: !r.reverted, error: r.reverted ? r.name : "" };
}

async function borrowProbe(e: Env, h: Holder, debtReserveId?: bigint, units = 10n): Promise<Probe> {
  const m = e.market(h.market);
  const id = debtReserveId ?? h.account.debtReserveId;
  const asset = (await e.read(e.registry, marketRegistryAbi, "getDebtReserve", [m.spoke, id]).catch(() => undefined))?.asset as Address | undefined;
  const decimals = asset && asset !== "0x0000000000000000000000000000000000000000" ? e.dec(asset) : 18;
  const nonce = (await e.read(e.adapter, aaveAdapterAbi, "borrowNonce", [h.account.proxy])) as bigint;
  return tryAs(e, h.owner, aaveAdapterAbi, "borrow", [m.marketId, id, units * 10n ** BigInt(decimals), h.owner, await e.deadline(), WAD, nonce]);
}

async function pledgeProbe(e: Env, s: State, market?: string, owner?: Address, position?: Position): Promise<Probe> {
  const m = e.market(market ?? s.pledger.market);
  return tryAs(e, owner ?? s.pledger.owner, aaveAdapterAbi, "pledge", [m.marketId, (position ?? s.pledger.position).ref, await e.deadline()]);
}

async function repayProbe(e: Env, h: Holder): Promise<Probe> {
  const m = e.market(h.market);
  return tryAs(e, h.owner, aaveAdapterAbi, "repay", [h.owner, m.marketId, h.account.debtReserveId, 10n ** 18n, false, await e.deadline()]);
}

/** The drill's record: each check, and whether it held. */
class Checks {
  readonly lines: string[] = [];
  failed = "";

  works(label: string, p: Probe) {
    this.lines.push(`${p.ok ? "ok  " : "FAIL"} ${label}: ${p.ok ? "works" : `refused ${p.error}`}`);
    if (!p.ok && !this.failed) this.failed = `${label} was refused (${p.error.slice(0, 120)})`;
  }

  refused(label: string, p: Probe, want: RegExp) {
    const ok = !p.ok && want.test(p.error);
    this.lines.push(`${ok ? "ok  " : "FAIL"} ${label}: ${p.ok ? "WORKS (expected a refusal)" : `refused ${p.error}`}${ok ? "" : ` (expected /${want.source}/)`}`);
    if (!ok && !this.failed) this.failed = p.ok ? `${label} still works after the forward change` : `${label} refused with ${p.error.slice(0, 120)}, expected /${want.source}/`;
  }

  that(label: string, ok: boolean, detail: string) {
    this.lines.push(`${ok ? "ok  " : "FAIL"} ${label}: ${detail}`);
    if (!ok && !this.failed) this.failed = `${label}: ${detail}`;
  }
}

// ─── Chain helpers ───

async function snapshot(e: Env): Promise<Hex> {
  return (await e.rpc("evm_snapshot")) as Hex;
}
async function revertTo(e: Env, id: Hex) {
  const ok = await e.rpc("evm_revert", [id]);
  if (ok !== true) throw new StepError(`evm_revert ${id} refused`);
  await e.rpc("evm_mine");
}
/** Moves the clock and publishes a fresh round on every feed, as the rehearsal's own waits do. */
async function wait(e: Env, seconds: number) {
  await e.advance(seconds);
  await e.refresh({}, Object.keys(e.prices));
}
async function pokeAll(e: Env) {
  for (const m of e.markets) await e.poke(m.lpOracle);
}

// ─── Setup ───

async function holder(e: Env, market: string, owner: Address, usdEach: bigint, borrowBps: bigint): Promise<Holder> {
  const m = e.market(market);
  const position = await e.mintPosition(m, owner, usdEach);
  const account = await e.pledge(m, owner, position);
  const max = await e.maxBorrow(m, owner, account);
  const amount = (max * borrowBps) / 10_000n;
  await e.ensureLiquidity(m, amount * 4n);
  await e.borrow(m, owner, account, amount, WAD);
  // Some of the debt asset, approved to the Adapter, so the repay probes can pay.
  const top = 1_000n * 10n ** BigInt(e.dec(m.debtAsset));
  await e.mint(m.debtAsset, owner, top);
  await e.approve(owner, m.debtAsset, e.adapter, maxUint256);
  return { market, owner, account, position };
}

async function setup(e: Env, c: Checks) {
  c.that("prices settled", true, await e.settle(true));
  const s: State = {
    borrower: await holder(e, M1, W.borrower, 20_000n, 2_000n),
    volBorrower: await holder(e, M2, W.volBorrower, 20_000n, 2_000n),
    slipBorrower: await holder(e, M4, W.slipBorrower, 20_000n, 2_000n),
    pledger: { market: M1, owner: W.pledger, position: await e.mintPosition(e.market(M1), W.pledger, 150_000n) },
  };
  mkdirSync(RECORDS, { recursive: true });
  writeFileSync(STATE, JSON.stringify(s, big, 2));
  for (const [k, h] of Object.entries({ borrower: s.borrower, volBorrower: s.volBorrower, slipBorrower: s.slipBorrower })) {
    const m = e.market(h.market);
    c.that(`${k} on ${h.market}`, true, `proxy ${h.account.proxy} debt ${await e.debt(m, h.account)} HF ${await e.healthFactor(m, h.account)}`);
  }
  c.works("pledger's 300k position can be pledged (simulated)", await pledgeProbe(e, s));
}

// ─── Drills ───

type Drill = (e: Env, c: Checks, log: string[]) => Promise<void>;

/** A guardian or timelock switch whose forward refuses a borrow (and optionally a pledge) and whose backward reopens it. */
function switchDrill(forward: string, backward: string, want: RegExp, opts: { pledge?: RegExp; holder?: keyof Pick<State, "borrower" | "volBorrower">; extra?: (keyof Pick<State, "borrower" | "volBorrower" | "slipBorrower">)[] } = {}): Drill {
  return async (e, c, log) => {
    const s = loadState();
    const h = s[opts.holder ?? "borrower"];
    await e.settle();
    c.works("before: borrow", await borrowProbe(e, h));
    if (opts.pledge) c.works("before: pledge", await pledgeProbe(e, s));
    mustApply(forward, log);
    await pokeAll(e);
    c.refused("forward: borrow", await borrowProbe(e, h), want);
    for (const x of opts.extra ?? []) c.refused(`forward: borrow on ${s[x].market}`, await borrowProbe(e, s[x]), want);
    if (opts.pledge) c.refused("forward: pledge by a new account", await pledgeProbe(e, s), opts.pledge);
    c.works("forward: repay stays open", await repayProbe(e, h));
    mustApply(backward, log);
    await e.settle();
    c.works("backward: borrow", await borrowProbe(e, h));
    for (const x of opts.extra ?? []) c.works(`backward: borrow on ${s[x].market}`, await borrowProbe(e, s[x]));
    if (opts.pledge) c.works("backward: pledge", await pledgeProbe(e, s));
  };
}

const DRILLS: Record<string, Drill> = {
  // Caps: the ParameterStore refuses a zero cap, so the drill asks for 0 (refused by the limit check), tightens the
  // stable Hub's depositor cap below a 300k pledge through the risk steward, then loosens it back in ×1.5 steps.
  async caps(e, c, log) {
    const s = loadState();
    await e.settle();
    c.works("before: 300k pledge", await pledgeProbe(e, s));
    const zero = changes("caps-zero.json", log);
    c.that("a zero cap is refused before anything is sent", zero.code === 2 && /zero cap/.test(zero.text), zero.text.split("\n").pop() ?? "");
    mustApply("caps-forward.json", log);
    c.refused("forward: 300k pledge above the 200k depositor cap", await pledgeProbe(e, s), /CapExceeded/);
    c.works("forward: borrow by an existing account", await borrowProbe(e, s.borrower));
    mustApply("caps-back.json", log);
    await e.settle();
    const hub = e.market(M1).hub;
    const cap = (await e.read(ctx.manifest.avana.parameterStore.address, parameterStoreAbi, "depositorUsdCap", [hub])) as bigint;
    const prior = JSON.parse(readFileSync(join(out, "changes-caps-forward.json"), "utf8")).changes[0].prior.value;
    c.that("backward: depositor cap restored", cap === BigInt(prior.$big ?? prior), `${cap} (was ${prior.$big ?? prior})`);
    c.works("backward: 300k pledge", await pledgeProbe(e, s));
  },

  // Aave: the CDP Spoke's GHO draw cap to 0 by AIP, then back to its value.
  "aave-caps-zero": switchDrill("aave-caps-zero-forward.json", "aave-caps-zero-back.json", /DrawCapExceeded/),

  "market-breaker": switchDrill("market-breaker-forward.json", "market-breaker-back.json", /BreakerTripped/, { pledge: /BreakerTripped/ }),

  "debt-breaker": switchDrill("debt-breaker-forward.json", "debt-breaker-back.json", /DebtBreakerTripped/),

  // Hub freeze through the timelock (short delay), unfreeze through the timelock (normal delay).
  "hub-freeze": switchDrill("hub-freeze-forward.json", "hub-freeze-back.json", /ApplicationFrozen/, { pledge: /ApplicationFrozen/ }),

  // Hub pause by the Emergency Guardian, unpause by the Aave Protocol Guardian.
  "hub-pause": switchDrill("hub-pause-forward.json", "hub-pause-back.json", /ApplicationPaused|NotRescueTopUp/, { pledge: /ApplicationPaused|NotRescueTopUp/ }),

  // pauseAll by the guardian; every Hub unpaused by one timelock operation (normal delay).
  "pause-all": switchDrill("pause-all-forward.json", "pause-all-back.json", /ApplicationPaused|NotRescueTopUp/, { extra: ["volBorrower", "slipBorrower"] }),

  // freezeAddress by the guardian; unfreezeAddress only through the timelock (normal delay).
  "freeze-address": switchDrill("freeze-address-forward.json", "freeze-address-back.json", /AddressIsFrozen/),

  // An Aave freeze of the market's vault-token reserve by AIP, and the unfreeze by AIP.
  "aave-freeze": switchDrill("aave-freeze-forward.json", "aave-freeze-back.json", /ReserveFrozen|AaveReserveUnavailable/, { pledge: /ReserveFrozen|AaveReserveUnavailable/ }),

  // P-02: USDC's primary feed reports 2 % low (disagreement with the alternate); the guardian switches the primary slot
  // to the listed standby; the feed is fixed and restorePriceRoute (timelock, normal delay) puts the primary back.
  async "oracle-standby"(e, c, log) {
    const s = loadState();
    const m = e.market(M1);
    const usdc = e.ctx.world.feeds.USDC as Record<string, Address>;
    await e.settle();
    c.works("before: borrow", await borrowProbe(e, s.borrower));
    const wrong = (e.prices.USDC! * 98n) / 100n;
    await e.ctx.client.waitForTransactionReceipt({ hash: await transmit(e.ctx.client, e.ctx.wallet, usdc.primaryAggregator!, wrong) });
    await e.poke(m.lpOracle);
    c.that("fault: LPOracle state", true, e.describe(await e.priceState(m.lpOracle)));
    c.refused("fault: borrow while USDC's routes disagree", await borrowProbe(e, s.borrower), /PriceNotLive|PriceNotAccepted|SecondSourceDisagrees/);
    mustApply("oracle-standby-forward.json", log);
    await e.poke(m.lpOracle);
    const routes = await e.read(e.registry, marketRegistryAbi, "activePriceRoutes", [e.token("USDC")]);
    c.that("standby in the primary slot", Number(routes[2]) === 1, `replaced slot ${routes[2]}; primary in force ${routes[0].join(",")}`);
    c.that("standby: LPOracle state", true, e.describe(await e.priceState(m.lpOracle)));
    c.works("standby: borrow", await borrowProbe(e, s.borrower));
    // The feed is fixed; the listed route comes back at the normal delay.
    await e.ctx.client.waitForTransactionReceipt({ hash: await transmit(e.ctx.client, e.ctx.wallet, usdc.primaryAggregator!, e.prices.USDC!) });
    mustApply("oracle-standby-back.json", log);
    await e.settle();
    const after = await e.read(e.registry, marketRegistryAbi, "activePriceRoutes", [e.token("USDC")]);
    c.that("backward: listed primary route restored", Number(after[2]) === 0 && after[0][0].toLowerCase() === usdc.primary!.toLowerCase(), `replaced slot ${after[2]}; primary ${after[0].join(",")}`);
    c.works("backward: borrow", await borrowProbe(e, s.borrower));
  },

  // The keeper operator's kill switch (services/keeper/src/safety/killSwitch.ts, mutual TLS): halt, then resume.
  async "keeper-kill-switch"(_e, c, log) {
    const work = join(tmpdir(), `avana-kill-${process.pid}`);
    mkdirSync(work, { recursive: true });
    const ssl = spawnSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost", "-keyout", join(work, "key.pem"), "-out", join(work, "cert.pem")], {
      encoding: "utf8",
      env: { ...process.env, MSYS2_ARG_CONV_EXCL: "/CN=" },
    });
    if (ssl.status !== 0) throw new NotRun(`openssl could not make the kill switch certificate: ${(ssl.stderr ?? "").split("\n")[0]}`);
    const port = Number(process.env.E2E_KILL_DRILL_PORT ?? 9475);
    const statePath = join(work, "halt");
    const state: SafetyState = { halted: false, codeMismatch: null, frozenHelperChains: new Set() };
    const events: string[] = [];
    const server = startKillSwitch({ port, cert: join(work, "cert.pem"), key: join(work, "key.pem"), clientCa: join(work, "cert.pem"), statePath }, state, (h, by) => events.push(`${h ? "halt" : "resume"} by ${by}`));
    const call = (method: string, path: string) =>
      new Promise<{ status: number; body: string }>((resolve, reject) => {
        const req = request(
          { host: "127.0.0.1", port, method, path, cert: readFileSync(join(work, "cert.pem")), key: readFileSync(join(work, "key.pem")), ca: readFileSync(join(work, "cert.pem")), servername: "localhost" },
          (res) => {
            let body = "";
            res.on("data", (d) => (body += d));
            res.on("end", () => resolve({ status: res.statusCode ?? 0, body }));
          },
        );
        req.on("error", reject);
        req.end();
      });
    try {
      await new Promise((r) => setTimeout(r, 300));
      c.that("before: keeper active", effectiveMode("active", true, state) === "active" && blockingReason("active", state, 31337) === null, "mode active, nothing blocks a submission");
      const noCert = await new Promise<string>((resolve) => {
        const req = request({ host: "127.0.0.1", port, method: "POST", path: "/halt", rejectUnauthorized: false }, (res) => resolve(`status ${res.statusCode}`));
        req.on("error", (err) => resolve(`refused: ${err.message.split("\n")[0]}`));
        req.end();
      });
      c.that("a halt without a client certificate is refused", state.halted === false && !/status 200/.test(noCert), noCert);
      const halt = await call("POST", "/halt");
      c.that("forward: POST /halt", halt.status === 200 && state.halted, `${halt.status} ${halt.body}`);
      const mode = effectiveMode("active", true, state);
      c.that("forward: submissions blocked", mode === "halted" && blockingReason(mode, state, 31337) === "halted", `mode ${mode}, blocking reason ${blockingReason(mode, state, 31337)}`);
      c.that("forward: halt persisted for a restart", readHalt(statePath), readFileSync(statePath, "utf8"));
      const resume = await call("POST", "/resume");
      const mode2 = effectiveMode("active", true, state);
      c.that("backward: POST /resume", resume.status === 200 && !state.halted && mode2 === "active" && blockingReason(mode2, state, 31337) === null, `${resume.status} ${resume.body}; mode ${mode2}`);
      c.that("backward: resume persisted", readHalt(statePath) === false, readFileSync(statePath, "utf8"));
      log.push(`kill switch events: ${events.join("; ")}`);
    } finally {
      server.close();
      rmSync(work, { recursive: true, force: true });
    }
  },

  // P-09: a 90 % WETH crash leaves a deficit on the volatile Hub's Uniswap CDP Spoke; the guardian trips the GHO debt
  // breaker, the COVERAGE_ROLE holder covers the deficit from the First-Loss Reserve, Avana Labs refunds the reserve to
  // its minimum (07-fund-first-loss-reserves) and the guardian resets the breaker.
  async "deficit-coverage"(e, c, log) {
    const s = loadState();
    const m = e.market(M2);
    const b = W.deficit;
    const keeper = (e.ctx.config.keepers as Address[])[0]!;
    await e.settle();
    c.works("before: borrow on the volatile Spoke", await borrowProbe(e, s.volBorrower));
    const p = await e.mintPosition(m, b, 50_000n);
    const a = await e.pledge(m, b, p);
    const amount = ((await e.maxBorrow(m, b, a)) * 9_900n) / 10_000n;
    await e.ensureLiquidity(m, amount);
    await e.borrow(m, b, a, amount, WAD);
    const d = e.dec(m.debtAsset);
    const debtUsd = ((await e.debt(m, a)) * 100_000_000n) / 10n ** BigInt(d);
    const coll = await e.collateralUsd8(m, a);
    const target = (debtUsd * m.maxLiquidationBonus * 9_500n) / (10_000n * 10_000n);
    const r = (target * target * 10_000n) / (coll * coll);
    await e.setWeth(r < 1_000n ? r : 1_000n, [m.lpOracle]);
    const hubAbi = aaveV4HubAbi;
    const assetId = (await e.read(m.hub, hubAbi, "getAssetId", [m.debtAsset])) as bigint;
    const liq = await e.liquidate(m, a, keeper, "drill", true);
    const deficit = (await e.read(m.hub, hubAbi, "getSpokeDeficitRay", [assetId, m.spoke])) as bigint;
    c.that("forward: deficit on the CDP Spoke", liq.ok && deficit > 0n, `liquidation ${liq.ok ? "ok" : liq.error}; deficit ${deficit} (ray units)`);
    await e.settle();
    mustApply("deficit-breaker-forward.json", log);
    c.refused("forward: GHO borrow on the volatile Spoke", await borrowProbe(e, s.volBorrower), /DebtBreakerTripped/);
    mustApply("deficit-cover.json", log);
    const left = (await e.read(m.hub, hubAbi, "getSpokeDeficitRay", [assetId, m.spoke])) as bigint;
    c.that("forward: deficit covered by the First-Loss Reserve", left === 0n, `deficit ${deficit} -> ${left}`);
    const reserve = e.ctx.file("coverage.json")?.[`AvanaFirstLossReserve.${e.hubLabel(m.hub)}.${e.sym(m.debtAsset)}`] as Address;
    const below = (await e.read(reserve, firstLossReserveAbi, "isBelowMinimum")) as boolean;
    c.that("forward: reserve below its minimum after covering", true, `isBelowMinimum ${below}`);
    // Backward: Avana Labs refunds the reserve to its minimum, then the breaker is reset.
    const fund = deployStep("07-fund-first-loss-reserves", log, { AVANA_CONFIG: currentConfig() });
    c.that("backward: 07-fund-first-loss-reserves", fund.code === 0, fund.code === 0 ? "ran" : fund.text.split("\n").filter((l) => /Error|revert/.test(l)).slice(0, 2).join(" "));
    const belowAfter = (await e.read(reserve, firstLossReserveAbi, "isBelowMinimum")) as boolean;
    c.that("backward: reserve at or above its minimum", !belowAfter, `isBelowMinimum ${belowAfter}; funded ${await e.read(reserve, firstLossReserveAbi, "fundedBalance")}`);
    mustApply("deficit-breaker-back.json", log);
    await e.settle();
    c.works("backward: GHO borrow on the volatile Spoke", await borrowProbe(e, s.volBorrower));
  },

  // Removing a debt reserve (USDT on slipVolatile, nothing owed): Aave makes it not borrowable by AIP, the timelock
  // removes it (normal delay); backward, Aave makes it borrowable again and the timelock enables it again.
  async "remove-debt-reserve"(e, c, log) {
    const s = loadState();
    const m = e.market(M4);
    const usdt = await reserveIdOf(e, m, "USDT");
    await e.settle();
    c.works("before: USDT borrow on slipVolatile", await borrowProbe(e, s.slipBorrower, usdt));
    mustApply("remove-debt-reserve-forward-aip.json", log);
    mustApply("remove-debt-reserve-forward.json", log);
    await e.settle();
    c.that("forward: removed from the registry", !(await e.read(e.registry, marketRegistryAbi, "isApprovedDebtReserve", [m.spoke, usdt])), `isApprovedDebtReserve false`);
    c.refused("forward: USDT borrow", await borrowProbe(e, s.slipBorrower, usdt), /UnknownDebtReserve|ReserveNotBorrowable/);
    c.works("forward: USDC borrow on the same Spoke", await borrowProbe(e, s.slipBorrower));
    await driftClear(e, c, m, "forward");
    mustApply("remove-debt-reserve-back-aip.json", log);
    mustApply("remove-debt-reserve-back.json", log);
    await e.settle();
    c.that("backward: enabled again", Boolean(await e.read(e.registry, marketRegistryAbi, "isApprovedDebtReserve", [m.spoke, usdt])), "isApprovedDebtReserve true");
    await driftClear(e, c, m, "backward");
    c.works("backward: USDT borrow", await borrowProbe(e, s.slipBorrower, usdt));
  },

  // Offboarding then close (permanent by design: REQ-CONFIG-013), inside a snapshot.
  async "offboard-close"(e, c, log) {
    const s = loadState();
    const m = e.market(M1);
    const snap = await snapshot(e);
    try {
      await e.settle();
      c.works("before: pledge", await pledgeProbe(e, s));
      mustApply("offboard-forward.json", log);
      mustApply("offboard-forward-aip.json", log);
      await pokeAll(e);
      c.refused("forward: pledge", await pledgeProbe(e, s), /MarketOffboarding|ReserveFrozen|AaveReserveUnavailable/);
      c.refused("forward: borrow", await borrowProbe(e, s.borrower), /MarketOffboarding|ReserveFrozen/);
      c.works("forward: repay stays open", await repayProbe(e, s.borrower));
      const early = await tryAs(e, W.anyone, marketRegistryAbi, "closeMarket", [m.marketId], e.registry);
      c.refused("forward: closeMarket during the notice", early, /OffboardNoticeRunning/);
      const debt = await e.debt(m, s.borrower.account);
      await e.must("repay all", s.borrower.owner, e.adapter, aaveAdapterAbi, "repay", [s.borrower.owner, m.marketId, s.borrower.account.debtReserveId, debt * 2n + 10n ** 18n, true, await e.deadline()]);
      await wait(e, 5 * 86_400 + 1);
      await e.must("closeMarket by anyone", W.anyone, e.registry, marketRegistryAbi, "closeMarket", [m.marketId]);
      const st = await e.read(e.registry, marketRegistryAbi, "getMarket", [m.marketId]);
      c.that("forward: market Closed", Number(st.status) === 5, `status ${st.status}`);
      c.refused("closed: pledge", await pledgeProbe(e, s), /MarketNotActive|MarketClosed|ReserveFrozen|AaveReserveUnavailable/);
      const units = await e.supplied(m, s.borrower.account);
      c.works("closed: debt-free withdrawal, no price read", await tryAs(e, s.borrower.owner, aaveAdapterAbi, "withdraw", [m.marketId, s.borrower.position.ref, units, await e.deadline(), 0n]));
      mustApply("offboard-back-aip.json", log);
      const cfg = await e.read(m.spoke, aaveV4SpokeAbi, "getReserveConfig", [st.reserveId]);
      c.that("backward: Aave reserve unfrozen", !cfg.frozen, `frozen ${cfg.frozen}; the market stays Closed (offboarding is permanent; a pool comes back only by relisting, P-19)`);
    } finally {
      await revertTo(e, snap);
      c.lines.push("chain reverted to the snapshot taken before the drill");
    }
  },

  // cancelRegistration of a market still Registered (a new range of USDC/USDT 0.01 % listed for the drill), then its
  // relisting under the reserved ID and activation; all inside a snapshot, so the drill market does not stay.
  async "cancel-registration"(e, c, log) {
    const base = currentConfig();
    const cfg = JSON.parse(readFileSync(join(CONTRACTS, base), "utf8"));
    const src = (cfg.listing.markets as any[]).find((x) => x.name === M1);
    if (!src) throw new NotRun(`${M1} not in ${base}`);
    const drillMarket = { ...src, name: `${M1}-drill`, tickLower: -100, tickUpper: 100, content: { ...(src.content ?? {}), slug: `${src.content?.slug ?? M1}-drill`, name: `${src.content?.name ?? M1} (drill range)` } };
    cfg.listing.markets = [...cfg.listing.markets, drillMarket];
    const drillConfig = "deployments-local/anvil/config-drill-relist.json";
    writeFileSync(join(CONTRACTS, drillConfig), `${JSON.stringify(cfg, null, 2)}\n`);
    const bak = join(out, ".drill-outputs");
    rmSync(bak, { recursive: true, force: true });
    cpSync(out, bak, { recursive: true, filter: (p) => !/[\\/](logs|anvil-state\.json|\.drill-outputs|\.hostile-outputs)$/.test(p) });
    const snap = await snapshot(e);
    const env = { AVANA_CONFIG: drillConfig };
    const run = (step: string) => {
      const r = deployStep(step, log, env);
      if (r.code !== 0) throw new StepError(`${step}: ${r.text.split("\n").filter((l) => /Error|revert/.test(l)).slice(0, 2).join(" ")}`);
    };
    try {
      run("09-market-metadata");
      run("09-listing-markets");
      await wait(e, 432_001);
      run("09-execute-listing-markets");
      const id = (await e.read(e.registry, marketRegistryAbi, "marketCount")) as bigint;
      const st = await e.read(e.registry, marketRegistryAbi, "getMarket", [id]);
      c.that("setup: drill market Registered", Number(st.status) === 1, `market ${id} status ${st.status}`);
      const fwd = cancelFile(id, "forward");
      mustApply(fwd, log);
      const st2 = await e.read(e.registry, marketRegistryAbi, "getMarket", [id]);
      c.that("forward: Cancelled", Number(st2.status) === 4, `status ${st2.status}`);
      // Backward: the same listing steps re-register the cancelled market under its reserved ID.
      run("09-market-metadata");
      run("09-listing-markets");
      await wait(e, 432_001);
      run("09-execute-listing-markets");
      const st3 = await e.read(e.registry, marketRegistryAbi, "getMarket", [id]);
      c.that("backward: re-registered under the reserved ID", Number(st3.status) === 1 && (await e.read(e.registry, marketRegistryAbi, "marketCount")) === id, `market ${id} status ${st3.status}`);
      run("10-aave-markets-aip");
      run("09-listing-activate");
      await wait(e, 43_201);
      run("09-execute-listing-activate");
      const st4 = await e.read(e.registry, marketRegistryAbi, "getMarket", [id]);
      c.that("backward: activated", Number(st4.status) === 2, `status ${st4.status}`);
      const fresh = "0x1000000000000000000000000000000000000d07" as Address;
      const listing = JSON.parse(readFileSync(join(out, "listing-markets.json"), "utf8"));
      const lm = Object.values(listing).find((x: any) => Number(x.marketId) === Number(id)) as any;
      if (lm) {
        const env2 = new Env(ctx);
        const mm = env2.market(lm.name) as Market;
        await env2.settle();
        const p = await env2.mintPosition(mm, fresh, 5_000n);
        c.works("backward: pledge into the relisted market", await tryAs(env2, fresh, aaveAdapterAbi, "pledge", [mm.marketId, p.ref, await env2.deadline()]));
      } else {
        c.that("backward: relisted market in listing-markets.json", false, "missing");
      }
    } finally {
      await revertTo(e, snap);
      cpSync(bak, out, { recursive: true });
      rmSync(bak, { recursive: true, force: true });
      rmSync(join(CONTRACTS, drillConfig), { force: true });
      c.lines.push("chain reverted to the snapshot taken before the drill; deployment outputs restored");
    }
  },

  // Retiring the growth Hub's credit lines (EMG-061): its only CDP Spoke's draw caps to 0 and its market's reserve
  // frozen by AIP, the market offboarded and closed, the GHO debt reserve removed; backward, the caps and the debt
  // reserve come back (the closed market stays closed). Inside a snapshot.
  async "retire-spoke"(e, c, log) {
    const m = e.market(M6);
    const s = loadState();
    const gho = await reserveIdOf(e, m, "GHO");
    const snap = await snapshot(e);
    try {
      await e.settle();
      const fresh = "0x1000000000000000000000000000000000000d08" as Address;
      const p = await e.mintPosition(m, fresh, 5_000n);
      c.works("before: pledge into the growth market", await pledgeProbe(e, s, M6, fresh, p));
      mustApply("retire-forward-aip.json", log);
      mustApply("retire-forward.json", log);
      await pokeAll(e);
      c.refused("forward: pledge into the growth market", await pledgeProbe(e, s, M6, fresh, p), /MarketOffboarding|ReserveFrozen|AaveReserveUnavailable/);
      await wait(e, 5 * 86_400 + 1);
      await e.must("closeMarket by anyone", W.anyone, e.registry, marketRegistryAbi, "closeMarket", [m.marketId]);
      mustApply("retire-forward-debt-aip.json", log);
      mustApply("retire-forward-debt.json", log);
      const active = (await e.read(e.registry, marketRegistryAbi, "activeMarketCount", [m.spoke])) as bigint;
      const enabled = (await e.read(e.registry, marketRegistryAbi, "getDebtReserveIds", [m.spoke])) as bigint[];
      const hubAbi = aaveV4HubAbi;
      const ghoAsset = (await e.read(m.hub, hubAbi, "getAssetId", [e.token("GHO")])) as bigint;
      const sc = await e.read(m.hub, hubAbi, "getSpokeConfig", [ghoAsset, m.spoke]);
      c.that("forward: Spoke retired", active === 0n && !enabled.includes(gho) && BigInt(sc.drawCap) === 0n, `active markets ${active}; debt reserves [${enabled.join(",")}]; GHO drawCap ${sc.drawCap}`);
      mustApply("retire-back-aip.json", log);
      mustApply("retire-back-debt-aip.json", log);
      mustApply("retire-back.json", log);
      const sc2 = await e.read(m.hub, hubAbi, "getSpokeConfig", [ghoAsset, m.spoke]);
      const enabled2 = (await e.read(e.registry, marketRegistryAbi, "isApprovedDebtReserve", [m.spoke, gho])) as boolean;
      c.that("backward: draw cap and GHO debt reserve back", BigInt(sc2.drawCap) > 0n && enabled2, `GHO drawCap ${sc2.drawCap}; approved ${enabled2}; market ${m.marketId} stays Closed (relisting is rehearsal 05)`);
    } finally {
      await revertTo(e, snap);
      c.lines.push("chain reverted to the snapshot taken before the drill");
    }
  },

  // Rehearsal 10: the GHO rate curve on the stable Hub raised by 1 % by AIP, then put back by AIP.
  async "rate-aip"(e, c, log) {
    const m = e.market(M1);
    const gho = e.token("GHO");
    const assetId = (await e.read(m.hub, aaveV4HubAbi, "getAssetId", [gho])) as bigint;
    const strategy = (await e.read(m.hub, aaveV4HubAbi, "getAssetConfig", [assetId])).irStrategy as Address;
    const before = await e.read(strategy, RATE_ABI, "getInterestRateData", [assetId]);
    const rate0 = (await e.read(m.hub, aaveV4HubAbi, "getAssetDrawnRate", [assetId])) as bigint;
    mustApply("rate-aip-forward.json", log);
    const mid = await e.read(strategy, RATE_ABI, "getInterestRateData", [assetId]);
    const rate1 = (await e.read(m.hub, aaveV4HubAbi, "getAssetDrawnRate", [assetId])) as bigint;
    c.that("forward: base drawn rate +100 bps", Number(mid.baseDrawnRate) === Number(before.baseDrawnRate) + 100 && rate1 > rate0, `base ${before.baseDrawnRate} -> ${mid.baseDrawnRate} bps; Hub drawn rate ${rate0} -> ${rate1} (ray)`);
    mustApply("rate-aip-back.json", log);
    const after = await e.read(strategy, RATE_ABI, "getInterestRateData", [assetId]);
    const rate2 = (await e.read(m.hub, aaveV4HubAbi, "getAssetDrawnRate", [assetId])) as bigint;
    const same = ["optimalUsageRatio", "baseDrawnRate", "rateGrowthBeforeOptimal", "rateGrowthAfterOptimal"].every((k) => Number(after[k]) === Number(before[k]));
    c.that("backward: rate curve restored exactly", same && rate2 < rate1, `${JSON.stringify(after, (_k, v) => (typeof v === "bigint" ? String(v) : v))}; Hub drawn rate ${rate2}`);
  },

  // Rehearsal 10: the same change under a delegated Aave rate role, when the DAO grants one.
  async "rate-role"(_e, c, log) {
    const r = changes("rate-role-forward.json", log);
    if (r.code === 3) throw new NotRun(r.text.split("\n").pop()!.replace(/^NOT AVAILABLE: /, ""));
    if (r.code !== 0) throw new StepError(`rate-role forward exited ${r.code}`);
    mustApply("rate-role-back.json", log);
    c.that("rate role", true, "forward and backward applied");
  },
};

/** The config the last release step used (the rehearsal exports it as AVANA_CONFIG). */
function currentConfig(): string {
  if (process.env.AVANA_CONFIG) return process.env.AVANA_CONFIG;
  for (const f of ["config-exotic.json", "config-day2.json"]) if (existsSync(join(out, f))) return `deployments-local/${ctx.network}/${f}`;
  return `script/deploy/config/${ctx.network}.json`;
}

async function reserveIdOf(e: Env, m: Market, sym: string): Promise<bigint> {
  const ids = (await e.read(e.registry, marketRegistryAbi, "getDebtReserveIds", [m.spoke])) as bigint[];
  for (const id of ids) {
    const d = await e.read(e.registry, marketRegistryAbi, "getDebtReserve", [m.spoke, id]);
    if (d.asset.toLowerCase() === e.token(sym).toLowerCase()) return id;
  }
  throw new NotRun(`no ${sym} debt reserve on ${m.spokeLabel}`);
}

/** The Spoke's settings match the registry (no CONFIG_DRIFT reason). */
async function driftClear(e: Env, c: Checks, m: Market, when: string) {
  const [marketId, reason] = (await e.read(e.registry, marketRegistryAbi, "spokeSettingsDrift", [m.spoke])) as [bigint, number];
  c.that(`${when}: no Spoke setting drift`, Number(reason) === 0, `spokeSettingsDrift market ${marketId} reason ${reason}`);
}

/** The cancelRegistration file for the drill market's ID (known only once it is listed). */
function cancelFile(id: bigint, kind: string): string {
  const path = join(RECORDS, `cancel-registration-${kind}.json`);
  mkdirSync(RECORDS, { recursive: true });
  writeFileSync(
    path,
    `${JSON.stringify({ name: `cancel-registration-${kind}`, description: "cancel the drill market while Registered (timelock, short delay)", via: "timelock", changes: [{ contract: "MarketRegistry", function: "cancelRegistration", args: { marketId: String(id) } }] }, null, 2)}\n`,
  );
  return path;
}

async function main() {
  const name = arg("drill");
  if (!name) throw new Error("usage: node script/e2e/drills.ts --network anvil --drill <name>");
  const c = new Checks();
  const log: string[] = [];
  let outcome: "pass" | "fail" | "not-run" = "pass";
  let detail = "";
  try {
    const e = new Env(ctx);
    if (name === "setup") await setup(e, c);
    else {
      const d = DRILLS[name];
      if (!d) throw new Error(`unknown drill ${name}; drills: ${Object.keys(DRILLS).join(", ")}`);
      await d(e, c, log);
    }
    if (c.failed) {
      outcome = "fail";
      detail = c.failed;
    } else {
      detail = c.lines.filter((l) => l.startsWith("ok")).map((l) => l.slice(4).split(":")[0]).join("; ");
    }
  } catch (err) {
    if (err instanceof NotRun) {
      outcome = "not-run";
      detail = err.message;
    } else {
      outcome = "fail";
      detail = err instanceof StepError ? err.message : ((err as Error).message.split("\n")[0] ?? String(err));
    }
  }
  mkdirSync(RECORDS, { recursive: true });
  writeFileSync(join(RECORDS, `${name}.json`), `${JSON.stringify({ drill: name, outcome, detail, checks: c.lines, log }, null, 2)}\n`);
  for (const l of log) process.stdout.write(`${l}\n`);
  for (const l of c.lines) process.stdout.write(`${l}\n`);
  process.stdout.write(`${outcome.toUpperCase()} ${detail}\n`);
  process.exitCode = outcome === "pass" ? 0 : outcome === "not-run" ? 3 : 1;
}

main().catch((err: unknown) => {
  process.stderr.write(`${(err as Error).stack ?? String(err)}\n`);
  process.exit(1);
});
