// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Step 11-changes <file>: an operator's changes to a live deployment (deploy recipe B8), from a JSON list. Each change
// is checked against its on-chain limit before anything is sent, then the whole list becomes one AvanaTimelock
// operation (scheduled as the governance Safe; on anvil also executed once its required delay has passed), one direct
// call from a guardian or the risk steward, one Aave AIP on Aave's config engine (AvanaAaveV4Payload, run by the
// governance executor), or a call under a delegated Aave rate role. Calldata is always encoded from the contracts' ABIs
// (packages/protocol/src/abis and the Aave payload artifact); the file names functions and arguments, never bytes.
//
// File format (examples in script/e2e/drills/):
//   {
//     "name": "market-breaker-forward",           unique; names the output files
//     "description": "…",
//     "via": "timelock" | "direct" | "aip" | "rate-role",
//     "sender": "emergencyGuardian",              direct only: a key of the config's `governance`
//     "restores": "market-breaker-forward",       optional: "$prior" values come from that earlier run
//     "changes": [
//       { "contract": "MarketRegistry", "function": "tripMarketBreaker", "args": { "marketId": "market:uni-USDC-USDT-100" } },
//       { "contract": "ParameterStore", "function": "loosenDepositorUsdCap", "args": { "hub": "hub:stable", "value": "$prior" },
//         "steps": true },                        a step-limited loosening split into ×1.5 operations, one per normal delay
//       { "aave": "spokeConfig", "hub": "hub:stable", "asset": "token:GHO", "spoke": "spoke:uniV3Stable", "set": { "drawCap": 0 } },
//       { "aave": "reserveConfig", "spoke": "spoke:uniV3Stable", "reserve": "collateral:uni-USDC-USDT-100", "set": { "frozen": true } },
//       { "aave": "assetRates", "hub": "hub:stable", "asset": "token:GHO", "set": { "baseDrawnRate": 300 } }
//     ]
//   }
// Contracts: MarketRegistry, ParameterStore, LPVaultSwap, AvanaFirstLossReserve (with "target": "reserve:<hub>:<SYMBOL>").
// References: market:<name>, hub:<label>, spoke:<label>, token:<SYMBOL>, vaultToken:<market name>, debtReserve:<spokeLabel>:<SYMBOL> (its reserve
// ID), collateral:<market name> (the vault-token reserve ID), reserve:<hub>:<SYMBOL> (a First-Loss Reserve),
// actor:<governance key>, "$prior" (the value the restored run found before its change), or a literal.
//
// Each run writes deployments-local/<network>/changes-<name>.json (the resolved changes, the values found before them,
// the operation or transaction) and, for a timelock run, operation-changes-<name>.json in the format of the deploy
// scripts' operations. Exit status: 0 applied (or written, off anvil), 2 refused by a limit check (nothing sent),
// 3 not available on this deployment (a delegated role Aave has not granted), 1 any other failure.
//
// Usage, from contracts/:  AVANA_NETWORK=anvil AVANA_RPC_URL=http://127.0.0.1:8545 script/deploy/step.sh 11-changes <file>

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  type Abi,
  type Address,
  type Hex,
  type PublicClient,
  createPublicClient,
  createWalletClient,
  decodeErrorResult,
  encodeAbiParameters,
  encodeFunctionData,
  getAddress,
  http,
  isAddress,
  keccak256,
  parseAbi,
  stringToHex,
  toHex,
} from "viem";
import {
  aaveV4HubAbi,
  aaveV4SpokeAbi,
  avanaTimelockAbi,
  firstLossReserveAbi,
  lpVaultSwapAbi,
  marketRegistryAbi,
  parameterStoreAbi,
} from "../../../packages/protocol/src/abis/index.ts";
import { refreshFeeds } from "../e2e/refresh-feeds.ts";

const CONTRACTS = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const network = process.env.AVANA_NETWORK ?? "anvil";
const rpc = process.env.AVANA_RPC_URL ?? process.env.RPC_ANVIL ?? "http://127.0.0.1:8545";
const OUT = join(CONTRACTS, "deployments-local", network);
const ANVIL = network === "anvil";
// refresh-feeds.ts sends its rounds to RPC_ANVIL.
process.env.RPC_ANVIL ??= rpc;

type Json = Record<string, any>;
const readJson = (f: string) => JSON.parse(readFileSync(f, "utf8")) as Json;
const out = (f: string) => readJson(join(OUT, f));
const outOr = (f: string) => (existsSync(join(OUT, f)) ? out(f) : undefined);
const config = readJson(process.env.AVANA_CONFIG ? join(CONTRACTS, process.env.AVANA_CONFIG) : join(CONTRACTS, "script/deploy/config", `${network}.json`));

const client = createPublicClient({ transport: http(rpc) }) as PublicClient;
const wallet = createWalletClient({ transport: http(rpc) });

/** A change the limit checks refuse; nothing is sent. */
class Refused extends Error {}
/** A path this deployment does not have (exit 3, reported not-run). */
class NotAvailable extends Error {}

// ─── The change file ───

interface CallChange {
  readonly contract: "MarketRegistry" | "ParameterStore" | "LPVaultSwap" | "AvanaFirstLossReserve";
  readonly function: string;
  readonly args: Record<string, unknown>;
  readonly target?: string;
  readonly steps?: boolean;
}
interface AaveChange {
  readonly aave: "spokeConfig" | "reserveConfig" | "assetRates";
  readonly hub?: string;
  readonly asset?: string;
  readonly spoke?: string;
  readonly reserve?: string;
  readonly set: Record<string, unknown>;
}
type Change = CallChange | AaveChange;
interface ChangesFile {
  readonly name: string;
  readonly description?: string;
  readonly via: "timelock" | "direct" | "aip" | "rate-role";
  readonly sender?: string;
  readonly restores?: string;
  readonly changes: readonly Change[];
}

// ─── Deployment outputs and references ───

const avana = out("avana.json");
const aave = out("aave.json");
const world = out("world.json");
const markets = Object.values(outOr("listing-markets.json") ?? {}) as Json[];
const coverage = outOr("coverage.json") ?? {};
const proxy = (v: any) => getAddress(typeof v === "string" ? v : v.proxy);
const REGISTRY = proxy(avana.marketRegistry);
const STORE = proxy(avana.parameterStore);
const TIMELOCK = proxy(avana.timelock);
const SWAP = proxy(avana.lpVaultSwap);

const ABIS: Record<CallChange["contract"], Abi> = {
  MarketRegistry: marketRegistryAbi as Abi,
  ParameterStore: parameterStoreAbi as Abi,
  LPVaultSwap: lpVaultSwapAbi as Abi,
  AvanaFirstLossReserve: firstLossReserveAbi as Abi,
};
/** Every Avana error, so a refused simulation is named whichever contract raised it. */
const ERRORS = [marketRegistryAbi, parameterStoreAbi, lpVaultSwapAbi, firstLossReserveAbi, avanaTimelockAbi, aaveV4HubAbi, aaveV4SpokeAbi]
  .flat()
  .filter((i: any) => i.type === "error") as Abi;

const read = (address: Address, abi: Abi, functionName: string, args: readonly unknown[] = []) =>
  client.readContract({ address, abi, functionName, args }) as Promise<any>;

function marketByName(name: string): Json {
  const m = markets.find((x) => x.name === name);
  if (!m) throw new Error(`market ${name} not in listing-markets.json`);
  return m;
}
function hubOf(label: string): Address {
  const h = aave.hubs?.[label];
  if (!h) throw new Error(`Hub ${label} not in aave.json`);
  return proxy(h);
}
function spokeOf(label: string): Address {
  const s = aave.spokes?.[label];
  if (!s) throw new Error(`Spoke ${label} not in aave.json`);
  return proxy(s);
}
function tokenOf(sym: string): Address {
  const t = world.tokens?.[sym];
  if (!t) throw new Error(`token ${sym} not in world.json`);
  return getAddress(t);
}
async function debtReserveId(spokeLabel: string, sym: string): Promise<bigint> {
  const spoke = spokeOf(spokeLabel);
  const asset = tokenOf(sym).toLowerCase();
  const ids = (await read(REGISTRY, marketRegistryAbi as Abi, "getDebtReserveIds", [spoke])) as bigint[];
  for (const id of ids) {
    const d = await read(REGISTRY, marketRegistryAbi as Abi, "getDebtReserve", [spoke, id]);
    if ((d.asset as string).toLowerCase() === asset) return id;
  }
  // A removed debt reserve leaves the registry's list; Aave's Spoke still names it.
  const hub = (await read(REGISTRY, marketRegistryAbi as Abi, "hubOf", [spoke]).catch(() => undefined)) as Address | undefined;
  if (hub) {
    const assetId = await read(hub, aaveV4HubAbi as Abi, "getAssetId", [getAddress(asset)]);
    return (await read(spoke, aaveV4SpokeAbi as Abi, "getReserveId", [hub, assetId])) as bigint;
  }
  throw new Error(`no ${sym} debt reserve on ${spokeLabel}`);
}

/** Resolves one argument value (see the header); `prior` is the value the restored run found. */
async function resolveValue(v: unknown, prior: unknown): Promise<unknown> {
  if (typeof v !== "string") return v;
  if (v === "$prior") {
    if (prior === undefined) throw new Error(`"$prior" needs "restores" naming an earlier run that recorded this change`);
    return revive(prior);
  }
  const [kind, a, b] = v.split(":");
  switch (kind) {
    case "market":
      return BigInt(marketByName(a!).marketId);
    case "hub":
      return hubOf(a!);
    case "spoke":
      return spokeOf(a!);
    case "token":
      return tokenOf(a!);
    case "vaultToken":
      return getAddress(marketByName(a!).vaultToken);
    case "debtReserve":
      return debtReserveId(a!, b!);
    case "collateral": {
      const m = await read(REGISTRY, marketRegistryAbi as Abi, "getMarket", [BigInt(marketByName(a!).marketId)]);
      return m.reserveId as bigint;
    }
    case "reserve": {
      const r = coverage[`AvanaFirstLossReserve.${a}.${b}`];
      if (!r) throw new Error(`no AvanaFirstLossReserve.${a}.${b} in coverage.json`);
      return getAddress(r);
    }
    case "actor": {
      const g = config.governance?.[a!];
      if (!g) throw new Error(`no governance.${a} in the config`);
      return getAddress(g);
    }
  }
  if (isAddress(v)) return getAddress(v);
  if (/^-?\d+$/.test(v)) return BigInt(v);
  return v;
}

/** JSON keeps bigints as `{ "$big": "…" }`. */
const freeze = (x: unknown): unknown =>
  typeof x === "bigint"
    ? { $big: x.toString() }
    : Array.isArray(x)
      ? x.map(freeze)
      : x && typeof x === "object"
        ? Object.fromEntries(Object.entries(x).map(([k, v]) => [k, freeze(v)]))
        : x;
const revive = (x: unknown): unknown =>
  x && typeof x === "object" && "$big" in (x as Json)
    ? BigInt((x as Json).$big)
    : Array.isArray(x)
      ? x.map(revive)
      : x && typeof x === "object"
        ? Object.fromEntries(Object.entries(x).map(([k, v]) => [k, revive(v)]))
        : x;
const show = (x: unknown) => JSON.stringify(freeze(x), (_k, v) => (v && typeof v === "object" && "$big" in v ? v.$big : v));

function errorName(e: unknown): string {
  let cur: any = e;
  for (let i = 0; cur && i < 10; i++) {
    const data = cur.data?.data ?? cur.data;
    if (typeof data === "string" && data.startsWith("0x") && data.length >= 10) {
      try {
        const d = decodeErrorResult({ abi: ERRORS, data: data as Hex });
        return `${d.errorName}(${(d.args ?? []).map(String).join(", ")})`;
      } catch {
        return `undecoded error ${data.slice(0, 10)}`;
      }
    }
    if (cur.data?.errorName) return `${cur.data.errorName}(${(cur.data.args ?? []).map(String).join(", ")})`;
    cur = cur.cause;
  }
  return (e as Error).message.split("\n")[0] ?? String(e);
}

// ─── Avana calls: encoding, the value before, the limit checks ───

interface Call {
  readonly label: string;
  readonly target: Address;
  readonly abi: Abi;
  readonly fn: string;
  readonly args: readonly unknown[];
  readonly data: Hex;
  readonly prior: unknown;
}

const CAPS: Record<string, { view: string; scopeArgs: number }> = {
  MarketUsdCap: { view: "marketUsdCap", scopeArgs: 1 },
  TokenUsdCap: { view: "tokenUsdCap", scopeArgs: 2 },
  DepositorUsdCap: { view: "depositorUsdCap", scopeArgs: 1 },
  TopUpSliceUsd: { view: "topUpSliceUsd", scopeArgs: 1 },
};

/** The ParameterStore view a tighten or loosen setter moves (`tightenX(scope…, value)` reads `x(scope…)`). */
function parameterView(fn: string): string | undefined {
  const m = /^(tighten|loosen)(.+)$/.exec(fn);
  if (!m) return undefined;
  const name = m[2]!;
  return name[0]!.toLowerCase() + name.slice(1);
}

async function buildCall(c: CallChange, prior: Json | undefined): Promise<Call> {
  const abi = ABIS[c.contract];
  if (!abi) throw new Error(`unknown contract ${c.contract}`);
  const item = (abi as any[]).find((i) => i.type === "function" && i.name === c.function);
  if (!item) throw new Error(`${c.contract} has no function ${c.function}`);
  const target =
    c.contract === "MarketRegistry"
      ? REGISTRY
      : c.contract === "ParameterStore"
        ? STORE
        : c.contract === "LPVaultSwap"
          ? SWAP
          : ((await resolveValue(c.target, undefined)) as Address);
  const args: unknown[] = [];
  for (const input of item.inputs as { name: string }[]) {
    if (!(input.name in c.args)) throw new Error(`${c.contract}.${c.function}: argument ${input.name} missing`);
    args.push(await resolveValue(c.args[input.name], prior?.[input.name]));
  }
  const data = encodeFunctionData({ abi, functionName: c.function, args });
  // The value before the change, for a later "$prior" restore.
  let before: unknown;
  const view = c.contract === "ParameterStore" ? parameterView(c.function) : undefined;
  if (view && (abi as any[]).some((i) => i.name === view)) {
    const scope = args.slice(0, -1);
    before = { value: await read(target, abi, view, scope).catch(() => undefined) };
  } else if (c.function === "removeDebtReserve") {
    before = { def: await read(REGISTRY, abi, "getDebtReserve", args) };
  }
  return { label: `${c.contract}.${c.function}(${show(args).slice(1, -1)})`, target, abi, fn: c.function, args, data, prior: before };
}

/** Limit checks that do not depend on who sends: the ParameterStore's hard bounds and loosening steps. */
async function checkLimits(call: Call, executesAt: bigint): Promise<string> {
  if (call.target !== STORE) return "";
  const m = /^(tighten|loosen)(MarketUsdCap|TokenUsdCap|DepositorUsdCap|TopUpSliceUsd)$/.exec(call.fn);
  if (!m) return "";
  const kind = m[1]!;
  const cap = CAPS[m[2]!]!;
  const scope = call.args.slice(0, cap.scopeArgs);
  const value = call.args[call.args.length - 1] as bigint;
  const current = (await read(STORE, parameterStoreAbi as Abi, cap.view, scope)) as bigint;
  if (kind === "tighten") {
    if (value === 0n) {
      throw new Refused(`${call.label}: the ParameterStore refuses a zero cap (OutOfBounds); to stop new exposure use a breaker, a pause or an Aave cap of 0`);
    }
    if (value >= current) throw new Refused(`${call.label}: not stricter than the current ${current} (NotStricter)`);
    // A loosening moves at most ×1.5 (⌊1 × 1.5⌋ = 1), so a cap at 1 can never be raised again: refused here.
    if (value < 2n) throw new Refused(`${call.label}: a cap of 1 (8-decimal USD) can never be loosened again (one step of ×1.5 from 1 is 1); use at least 2`);
    if (cap.view === "marketUsdCap") {
      const slice = (await read(STORE, parameterStoreAbi as Abi, "topUpSliceUsd", scope)) as bigint;
      if (value < slice) throw new Refused(`${call.label}: below the market's topUpSliceUsd ${slice} (OutOfBounds)`);
    }
    return `${cap.view} ${current} -> ${value}; restoring takes ${stepsBetween(value, current)} loosening(s) of ×1.5, one per normal delay`;
  }
  const stepBps = BigInt(await read(STORE, parameterStoreAbi as Abi, "LOOSEN_CAP_STEP_BPS"));
  if (value <= current) throw new Refused(`${call.label}: not looser than the current ${current} (NotLooser)`);
  // The top-up slice steps from max(current, marketUsdCap / 10); the other caps from the current value.
  let base = current;
  if (cap.view === "topUpSliceUsd") {
    const marketCap = (await read(STORE, parameterStoreAbi as Abi, "marketUsdCap", scope)) as bigint;
    if (marketCap / 10n > base) base = marketCap / 10n;
  }
  if (value * 10_000n > base * stepBps) {
    throw new Refused(`${call.label}: ${value} is above one step of ×${Number(stepBps) / 10_000} from ${base} (LoosenStepTooLarge)`);
  }
  const scopeWord =
    cap.scopeArgs === 2
      ? keccak256(encodeAbiParameters([{ type: "address" }, { type: "address" }], scope as [Address, Address]))
      : typeof scope[0] === "string"
        ? (toHex(BigInt(scope[0] as string), { size: 32 }) as Hex)
        : (toHex(scope[0] as bigint, { size: 32 }) as Hex);
  const key = keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "bytes32" }], [stringToHex(cap.view, { size: 32 }), scopeWord]));
  const last = BigInt(await read(STORE, parameterStoreAbi as Abi, "lastLoosenedAt", [key]));
  const normal = BigInt(await read(TIMELOCK, avanaTimelockAbi as Abi, "normalDelay"));
  if (last !== 0n && executesAt < last + normal) {
    throw new Refused(`${call.label}: the last loosening was at ${last}; the next may run from ${last + normal} (LoosenTooSoon), this one would run at ${executesAt}`);
  }
  return `${cap.view} ${current} -> ${value} (within one step of ×${Number(stepBps) / 10_000})`;
}

function stepsBetween(from: bigint, to: bigint): number {
  let n = 0;
  // ⌊1.5 v⌋ stays at 1 for v = 1; the contract's step check (`value × 10⁴ ≤ v × 15,000`) then allows only v itself.
  for (let v = from; v < to; n++) {
    const next = (v * 3n) / 2n;
    if (next <= v) return Number.POSITIVE_INFINITY;
    v = next;
  }
  return n;
}

/** Simulates the call as `from` at the current block; a revert refuses it, named. `tolerate` lists errors a limit check already settled for the execution time. */
async function simulate(from: Address, call: Call, tolerate: RegExp = /$^/): Promise<void> {
  try {
    await client.call({ account: from, to: call.target, data: call.data });
  } catch (e) {
    const name = errorName(e);
    if (tolerate.test(name)) return;
    throw new Refused(`${call.label} as ${from}: ${name}`);
  }
}

// ─── Timelock and direct runs ───

const ZERO32 = `0x${"00".repeat(32)}` as Hex;

async function rpcCall(method: string, params: unknown[] = []) {
  return client.request({ method: method as any, params: params as any });
}

async function sendTx(from: Address, to: Address, data: Hex): Promise<Hex> {
  if (ANVIL) await rpcCall("anvil_setBalance", [from, "0x3635C9ADC5DEA00000"]).catch(() => undefined);
  const gas = (await client.estimateGas({ account: from, to, data })) * 13n / 10n + 50_000n;
  const hash = await wallet.sendTransaction({ account: from, to, data, chain: null, gas });
  const r = await client.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`transaction ${hash} to ${to} reverted`);
  return hash;
}

async function advance(seconds: bigint) {
  await rpcCall("evm_increaseTime", [Number(seconds)]);
  await rpcCall("evm_mine", []);
  // A live Chainlink network publishes at least once per heartbeat; the rehearsal moves the clock, so every feed gets a round.
  await refreshFeeds(client, network);
}

async function runTimelock(name: string, calls: Call[], log: string[]): Promise<Json> {
  const safe = getAddress(config.governance.governanceSafe);
  const targets = calls.map((c) => c.target);
  const payloads = calls.map((c) => c.data);
  const values = calls.map(() => 0n);
  const tl = avanaTimelockAbi as Abi;
  const delay = (await read(TIMELOCK, tl, "requiredDelay", [targets, payloads])) as bigint;
  const now = (await client.getBlock()).timestamp;
  for (const c of calls) {
    const note = await checkLimits(c, now + delay + 1n);
    if (note) log.push(`  limit ok: ${note}`);
    // Who executes is the timelock; a loosening's spacing was checked above for the execution time.
    await simulate(TIMELOCK, c, /^LoosenTooSoon/);
  }
  let salt = keccak256(stringToHex(`avana.${config.release ?? "local"}.changes.${name}`));
  let id = (await read(TIMELOCK, tl, "hashOperationBatch", [targets, values, payloads, ZERO32, salt])) as Hex;
  if (await read(TIMELOCK, tl, "isOperation", [id])) {
    salt = keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [salt, now]));
    id = (await read(TIMELOCK, tl, "hashOperationBatch", [targets, values, payloads, ZERO32, salt])) as Hex;
  }
  const scheduleData = encodeFunctionData({ abi: tl, functionName: "scheduleBatch", args: [targets, values, payloads, ZERO32, salt, delay] });
  const executeData = encodeFunctionData({ abi: tl, functionName: "executeBatch", args: [targets, values, payloads, ZERO32, salt] });
  const op = {
    name: `changes-${name}`,
    chainId: await client.getChainId(),
    timelock: TIMELOCK,
    id,
    salt,
    predecessor: ZERO32,
    delay: Number(delay),
    targets,
    values: values.map(String),
    payloads,
    labels: calls.map((c) => c.label),
    executeBatchCalldata: executeData,
    scheduleBatchCalldata: scheduleData,
  };
  writeFileSync(join(OUT, `operation-changes-${name}.json`), `${JSON.stringify(op, null, 2)}\n`);
  log.push(`changes-${name} ${id} (delay ${delay} s) ${join(OUT, `operation-changes-${name}.json`)}`);
  if (!ANVIL) return { operation: id, delay: Number(delay), scheduled: false };
  const scheduled = await sendTx(safe, TIMELOCK, scheduleData);
  log.push(`  scheduled as the governance Safe ${safe}: ${scheduled}`);
  await advance(delay + 1n);
  // Right before execution the batch is simulated as the executor; a call that would now revert is named.
  try {
    await client.call({ account: safe, to: TIMELOCK, data: executeData });
  } catch (e) {
    throw new Error(`executeBatch would revert: ${errorName(e)}`);
  }
  const executed = await sendTx(safe, TIMELOCK, executeData);
  log.push(`  executed after ${delay} s: ${executed}`);
  return { operation: id, delay: Number(delay), scheduledTx: scheduled, executedTx: executed };
}

async function runDirect(sender: Address, calls: Call[], log: string[]): Promise<Json> {
  if (calls.length !== 1) throw new Refused(`a direct run is one call from one Safe; this file has ${calls.length} (use the timelock for a batch)`);
  const c = calls[0]!;
  const note = await checkLimits(c, (await client.getBlock()).timestamp);
  if (note) log.push(`  limit ok: ${note}`);
  await simulate(sender, c);
  if (!ANVIL) {
    log.push(`  for the Safe ${sender}: to ${c.target} data ${c.data}`);
    return { to: c.target, data: c.data, sent: false };
  }
  const tx = await sendTx(sender, c.target, c.data);
  log.push(`  sent by ${sender}: ${tx}`);
  return { tx };
}

// ─── Aave AIPs on the config engine ───

const KEEP = 2n ** 256n - 1n - 652n;
const KEEP_ADDRESS = getAddress("0xffffffffffffffffffffffffffffffffffffffff");
const KEEP_U16 = 2 ** 16 - 1 - 61;
const KEEP_U32 = 2 ** 32 - 1 - 23;
const RATE_ABI = parseAbi([
  "function getInterestRateData(uint256 assetId) view returns ((uint16 optimalUsageRatio, uint32 baseDrawnRate, uint32 rateGrowthBeforeOptimal, uint32 rateGrowthAfterOptimal))",
  "function MAX_ALLOWED_DRAWN_RATE() view returns (uint256)",
  "function MIN_OPTIMAL_RATIO() view returns (uint256)",
  "function MAX_OPTIMAL_RATIO() view returns (uint256)",
]);
const EXECUTOR_ABI = parseAbi([
  "function executeTransaction(address target, uint256 value, string signature, bytes data, bool withDelegatecall) payable returns (bytes)",
]);

interface AaveActions {
  roleMemberships: unknown[];
  roleUpdates: unknown[];
  targetFunctionRoleUpdates: unknown[];
  assetListings: unknown[];
  spokeToAssetsAdditions: unknown[];
  spokeConfigUpdates: Json[];
  reserveListings: unknown[];
  reserveConfigUpdates: Json[];
  liquidationConfigUpdates: unknown[];
  postCalls: unknown[];
  assetConfigUpdates: Json[];
}

const asBool = (v: unknown) => (v === true || v === 1n || v === "true" ? 1n : v === false || v === 0n || v === "false" ? 0n : KEEP);

async function buildAave(c: AaveChange, prior: Json | undefined, actions: AaveActions, log: string[]): Promise<{ label: string; prior: unknown }> {
  const set: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(c.set)) set[k] = await resolveValue(v, prior?.[k]);
  if (c.aave === "spokeConfig") {
    const hub = (await resolveValue(c.hub, undefined)) as Address;
    const asset = (await resolveValue(c.asset, undefined)) as Address;
    const spoke = (await resolveValue(c.spoke, undefined)) as Address;
    const assetId = await read(hub, aaveV4HubAbi as Abi, "getAssetId", [asset]);
    const cur = await read(hub, aaveV4HubAbi as Abi, "getSpokeConfig", [assetId, spoke]);
    const max = BigInt(await read(hub, aaveV4HubAbi as Abi, "MAX_ALLOWED_SPOKE_CAP"));
    for (const k of ["addCap", "drawCap"]) {
      if (set[k] !== undefined && BigInt(set[k] as bigint) > max) throw new Refused(`spokeConfig ${k} ${set[k]} above the Hub's MAX_ALLOWED_SPOKE_CAP ${max}`);
    }
    actions.spokeConfigUpdates.push({
      hubConfigurator: getAddress(aave.hubConfigurator),
      hub,
      underlying: asset,
      spoke,
      addCap: set.addCap === undefined ? KEEP : BigInt(set.addCap as bigint),
      drawCap: set.drawCap === undefined ? KEEP : BigInt(set.drawCap as bigint),
      riskPremiumThreshold: set.riskPremiumThreshold === undefined ? KEEP : BigInt(set.riskPremiumThreshold as bigint),
      active: set.active === undefined ? KEEP : asBool(set.active),
      halted: set.halted === undefined ? KEEP : asBool(set.halted),
    });
    const before = { addCap: cur.addCap, drawCap: cur.drawCap, riskPremiumThreshold: cur.riskPremiumThreshold, active: cur.active, halted: cur.halted };
    return { label: `spokeConfig(hub ${hub}, ${asset}, spoke ${spoke}) ${show(set)} (was ${show(before)})`, prior: before };
  }
  if (c.aave === "reserveConfig") {
    const spoke = (await resolveValue(c.spoke, undefined)) as Address;
    const reserveId = (await resolveValue(c.reserve, undefined)) as bigint;
    const cur = await read(spoke, aaveV4SpokeAbi as Abi, "getReserveConfig", [reserveId]);
    const r = await read(spoke, aaveV4SpokeAbi as Abi, "getReserve", [reserveId]);
    actions.reserveConfigUpdates.push({
      spokeConfigurator: getAddress(aave.spokeConfigurator),
      spoke,
      hub: r.hub,
      underlying: r.underlying,
      priceSource: KEEP_ADDRESS,
      collateralRisk: set.collateralRisk === undefined ? KEEP : BigInt(set.collateralRisk as bigint),
      paused: set.paused === undefined ? KEEP : asBool(set.paused),
      frozen: set.frozen === undefined ? KEEP : asBool(set.frozen),
      borrowable: set.borrowable === undefined ? KEEP : asBool(set.borrowable),
      receiveSharesEnabled: set.receiveSharesEnabled === undefined ? KEEP : asBool(set.receiveSharesEnabled),
    });
    const before = { collateralRisk: cur.collateralRisk, paused: cur.paused, frozen: cur.frozen, borrowable: cur.borrowable, receiveSharesEnabled: cur.receiveSharesEnabled };
    return { label: `reserveConfig(spoke ${spoke}, reserve ${reserveId}) ${show(set)} (was ${show(before)})`, prior: before };
  }
  if (c.aave === "assetRates") {
    const hub = (await resolveValue(c.hub, undefined)) as Address;
    const asset = (await resolveValue(c.asset, undefined)) as Address;
    const assetId = await read(hub, aaveV4HubAbi as Abi, "getAssetId", [asset]);
    const cfg = await read(hub, aaveV4HubAbi as Abi, "getAssetConfig", [assetId]);
    const cur = await read(cfg.irStrategy, RATE_ABI, "getInterestRateData", [assetId]);
    const next = rateCurve(cur, set);
    await checkRates(cfg.irStrategy, next);
    actions.assetConfigUpdates.push({
      hubConfigurator: getAddress(aave.hubConfigurator),
      hub,
      underlying: asset,
      liquidityFee: KEEP,
      feeReceiver: KEEP_ADDRESS,
      irStrategy: KEEP_ADDRESS,
      irData: {
        optimalUsageRatio: set.optimalUsageRatio === undefined ? KEEP_U16 : next.optimalUsageRatio,
        baseDrawnRate: set.baseDrawnRate === undefined ? KEEP_U32 : next.baseDrawnRate,
        rateGrowthBeforeOptimal: set.rateGrowthBeforeOptimal === undefined ? KEEP_U32 : next.rateGrowthBeforeOptimal,
        rateGrowthAfterOptimal: set.rateGrowthAfterOptimal === undefined ? KEEP_U32 : next.rateGrowthAfterOptimal,
      },
      reinvestmentController: KEEP_ADDRESS,
    });
    const before = { ...cur };
    log.push(`  limit ok: rate curve within the strategy's bounds: ${show(next)}`);
    return { label: `assetRates(hub ${hub}, ${asset}) ${show(set)} (was ${show(before)})`, prior: before };
  }
  throw new Error(`unknown Aave change ${(c as Json).aave}`);
}

const RATE_FIELDS = ["optimalUsageRatio", "baseDrawnRate", "rateGrowthBeforeOptimal", "rateGrowthAfterOptimal"] as const;
type RateCurve = Record<(typeof RATE_FIELDS)[number], number>;

/** The curve after `set`: a number replaces a field, `{ "add": n }` moves it by n bps. */
function rateCurve(cur: Json, set: Record<string, unknown>): RateCurve {
  const next = {} as RateCurve;
  for (const k of RATE_FIELDS) {
    const v = set[k];
    const now = Number(cur[k]);
    next[k] = v === undefined ? now : v && typeof v === "object" && "add" in (v as Json) ? now + Number((v as Json).add) : Number(v);
    if (!Number.isInteger(next[k]) || next[k] < 0) throw new Refused(`rate field ${k}: ${show(v)} gives ${next[k]}`);
  }
  for (const k of Object.keys(set)) if (!(RATE_FIELDS as readonly string[]).includes(k)) throw new Error(`unknown rate field ${k}`);
  return next;
}

/** The strategy's own bounds: optimal usage ratio and the summed maximum drawn rate (AssetInterestRateStrategy). */
async function checkRates(strategy: Address, d: { optimalUsageRatio: number; baseDrawnRate: number; rateGrowthBeforeOptimal: number; rateGrowthAfterOptimal: number }) {
  const [maxRate, minOpt, maxOpt] = (await Promise.all([
    read(strategy, RATE_ABI, "MAX_ALLOWED_DRAWN_RATE"),
    read(strategy, RATE_ABI, "MIN_OPTIMAL_RATIO"),
    read(strategy, RATE_ABI, "MAX_OPTIMAL_RATIO"),
  ])) as bigint[];
  if (BigInt(d.optimalUsageRatio) < minOpt! || BigInt(d.optimalUsageRatio) > maxOpt!) {
    throw new Refused(`optimalUsageRatio ${d.optimalUsageRatio} outside [${minOpt}, ${maxOpt}] (InvalidOptimalUsageRatio)`);
  }
  const sum = BigInt(d.baseDrawnRate + d.rateGrowthBeforeOptimal + d.rateGrowthAfterOptimal);
  if (sum > maxRate!) throw new Refused(`maximum drawn rate ${sum} bps above MAX_ALLOWED_DRAWN_RATE ${maxRate} (InvalidMaxDrawnRate)`);
}

/** The payload artifact: its creation code and the ABI of `actions()`, whose output is the encoding of AvanaAaveActions. */
function payloadArtifact() {
  const f = join(CONTRACTS, "out/AvanaAaveV4Payload.sol/AvanaAaveV4Payload.json");
  if (!existsSync(f)) throw new Error(`${f} missing: forge build`);
  const a = readJson(f);
  const actions = (a.abi as any[]).find((i) => i.type === "function" && i.name === "actions");
  return { bytecode: a.bytecode.object as Hex, abi: a.abi as Abi, actionsOutput: actions.outputs as any[] };
}

/** SSTORE2 data contract: init code that returns `0x00 ‖ data` as runtime (the same layout solady's SSTORE2.write deploys). */
function dataContractInit(data: Hex): Hex {
  const body = `00${data.slice(2)}`;
  const size = body.length / 2;
  if (size > 0xffff) throw new Error("data chunk too large");
  return `0x61${size.toString(16).padStart(4, "0")}80600a3d393df3${body}` as Hex;
}

async function deploy(from: Address, data: Hex): Promise<Address> {
  if (ANVIL) await rpcCall("anvil_setBalance", [from, "0x3635C9ADC5DEA00000"]).catch(() => undefined);
  const hash = await wallet.sendTransaction({ account: from, data, chain: null, gas: 15_000_000n });
  const r = await client.waitForTransactionReceipt({ hash });
  if (r.status !== "success" || !r.contractAddress) throw new Error(`deployment ${hash} failed`);
  return getAddress(r.contractAddress);
}

async function runAip(name: string, actions: AaveActions, log: string[]): Promise<Json> {
  const art = payloadArtifact();
  const encoded = encodeAbiParameters(art.actionsOutput, [actions]);
  const file = join(OUT, `aip-changes-${name}.json`);
  const record: Json = {
    name: `changes-${name}`,
    configEngine: aave.configEngine,
    executor: config.aaveLocal?.aaveDao ?? config.governance.aaveGovernanceExecutor,
    actions: encoded,
    decoded: freeze(actions),
  };
  if (!ANVIL) {
    writeFileSync(file, `${JSON.stringify(record, null, 2)}\n`);
    log.push(`AIP changes-${name}: actions written for the AIP author ${file}`);
    return { aip: file, executed: false };
  }
  const deployer = getAddress(config.aavePayload?.tokenMinter ?? "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
  const CHUNK = 24_000;
  const bytes = encoded.slice(2);
  const pointers: Address[] = [];
  for (let i = 0; i < bytes.length; i += CHUNK * 2) pointers.push(await deploy(deployer, dataContractInit(`0x${bytes.slice(i, i + CHUNK * 2)}` as Hex)));
  if (pointers.length > 4) throw new Error("the AIP's actions need more than the payload's four data chunks");
  const ctor = encodeAbiParameters([{ type: "address" }, { type: "address[]" }], [getAddress(aave.configEngine), pointers]);
  const payload = await deploy(deployer, `${art.bytecode}${ctor.slice(2)}` as Hex);
  const executor = getAddress(record.executor);
  const controller = getAddress(config.aaveLocal.payloadsController);
  const data = encodeFunctionData({ abi: EXECUTOR_ABI, functionName: "executeTransaction", args: [payload, 0n, "execute()", "0x", true] });
  try {
    await client.call({ account: controller, to: executor, data });
  } catch (e) {
    throw new Refused(`AIP changes-${name} would revert when executed: ${errorName(e)}`);
  }
  const tx = await sendTx(controller, executor, data);
  Object.assign(record, { payload, dataChunks: pointers, executedTx: tx });
  writeFileSync(file, `${JSON.stringify(record, null, 2)}\n`);
  log.push(`AIP changes-${name} payload ${payload}`);
  log.push(`  executed by the governance executor ${executor}: ${tx}`);
  return { aip: file, payload, executedTx: tx };
}

// ─── Delegated Aave rate role ───

/**
 * A rate change under a role the Aave DAO delegates to Avana on HubConfigurator.updateInterestRateData. The role ID,
 * its holder and its bounds come from Aave (config `aaveDelegatedRateRole`: { roleId, holder, maxStepBps, ... }); until
 * Aave provides them the path is not available and the run says so (exit 3), never a pass.
 */
async function runRateRole(changes: readonly Change[], prior: Json[] | undefined, log: string[]): Promise<Json> {
  const role = config.aaveDelegatedRateRole;
  if (!role?.roleId || !role?.holder) {
    throw new NotAvailable(
      "no delegated Aave rate role: the Aave DAO has not granted Avana one, so its role ID, holder and bounds are unknown (config aaveDelegatedRateRole)",
    );
  }
  const ACCESS = parseAbi(["function canCall(address caller, address target, bytes4 selector) view returns (bool immediate, uint32 delay)"]);
  const CONFIGURATOR = parseAbi([
    "function updateInterestRateData(address hub, uint256 assetId, bytes irData)",
  ]);
  const holder = getAddress(role.holder);
  const configurator = getAddress(aave.hubConfigurator);
  const selector = encodeFunctionData({ abi: CONFIGURATOR, functionName: "updateInterestRateData", args: [configurator, 0n, "0x"] }).slice(0, 10) as Hex;
  const [immediate] = (await read(getAddress(aave.accessManager), ACCESS as Abi, "canCall", [holder, configurator, selector])) as [boolean, number];
  if (!immediate) throw new NotAvailable(`role ${role.roleId}: ${holder} cannot call updateInterestRateData on chain (AccessManager.canCall false)`);
  const results: Json[] = [];
  for (const [i, c] of changes.entries()) {
    if (!("aave" in c) || c.aave !== "assetRates") throw new Refused("the delegated rate role changes only rate curves (assetRates)");
    const hub = (await resolveValue(c.hub, undefined)) as Address;
    const asset = (await resolveValue(c.asset, undefined)) as Address;
    const assetId = await read(hub, aaveV4HubAbi as Abi, "getAssetId", [asset]);
    const cfg = await read(hub, aaveV4HubAbi as Abi, "getAssetConfig", [assetId]);
    const cur = await read(cfg.irStrategy, RATE_ABI, "getInterestRateData", [assetId]);
    const set: Json = {};
    for (const [k, v] of Object.entries(c.set)) set[k] = await resolveValue(v, prior?.[i]?.[k]);
    const next = rateCurve(cur, set);
    await checkRates(cfg.irStrategy, next);
    const step = BigInt(role.maxStepBps ?? 0);
    for (const k of ["baseDrawnRate", "rateGrowthBeforeOptimal", "rateGrowthAfterOptimal"]) {
      const d = BigInt(Math.abs(next[k as keyof RateCurve] - Number(cur[k])));
      if (step > 0n && d > step) throw new Refused(`${k} moves ${d} bps, above the role's step of ${step} bps`);
    }
    const irData = encodeAbiParameters(
      [{ type: "tuple", components: [{ name: "a", type: "uint16" }, { name: "b", type: "uint32" }, { name: "c", type: "uint32" }, { name: "d", type: "uint32" }] }],
      [{ a: next.optimalUsageRatio, b: next.baseDrawnRate, c: next.rateGrowthBeforeOptimal, d: next.rateGrowthAfterOptimal }],
    );
    const data = encodeFunctionData({ abi: CONFIGURATOR, functionName: "updateInterestRateData", args: [hub, assetId, irData] });
    const tx = ANVIL ? await sendTx(holder, configurator, data) : undefined;
    log.push(`  rate role ${role.roleId} by ${holder}: ${show(set)} ${tx ?? "(written)"}`);
    results.push({ prior: { ...cur }, tx, data });
  }
  return { results };
}

// ─── Main ───

async function main() {
  const fileArg = process.argv[2];
  if (!fileArg) throw new Error("usage: script/deploy/step.sh 11-changes <file>");
  const path = isAbsolute(fileArg) ? fileArg : resolve(process.cwd(), fileArg);
  const f = readJson(path) as ChangesFile;
  if (!/^[A-Za-z0-9._-]+$/.test(f.name ?? "")) throw new Error(`${path}: "name" must be a plain identifier`);
  if (!Array.isArray(f.changes) || f.changes.length === 0) throw new Error(`${path}: no changes`);
  const restored = f.restores ? outOr(`changes-${f.restores}.json`) : undefined;
  if (f.restores && !restored) throw new Error(`"restores": ${f.restores} has not run (no changes-${f.restores}.json)`);
  const priorOf = (i: number) => revive(restored?.changes?.[i]?.prior) as Json | undefined;
  const log: string[] = [`changes ${f.name} via ${f.via}${f.description ? `: ${f.description}` : ""}`];
  const record: Json = { name: f.name, via: f.via, file: path, at: Number((await client.getBlock()).timestamp), changes: [] as Json[] };

  if (f.via === "rate-role") {
    record.result = await runRateRole(f.changes, f.changes.map((_, i) => priorOf(i)) as Json[], log);
    record.changes = (record.result.results as Json[]).map((r) => ({ prior: freeze(r.prior) }));
  } else if (f.via === "aip") {
    const actions: AaveActions = {
      roleMemberships: [],
      roleUpdates: [],
      targetFunctionRoleUpdates: [],
      assetListings: [],
      spokeToAssetsAdditions: [],
      spokeConfigUpdates: [],
      reserveListings: [],
      reserveConfigUpdates: [],
      liquidationConfigUpdates: [],
      postCalls: [],
      assetConfigUpdates: [],
    };
    for (const [i, c] of f.changes.entries()) {
      if (!("aave" in c)) throw new Error("an AIP holds Aave changes only");
      const b = await buildAave(c, priorOf(i), actions, log);
      log.push(`  ${b.label}`);
      record.changes.push({ change: c, label: b.label, prior: freeze(b.prior) });
    }
    record.result = await runAip(f.name, actions, log);
  } else {
    if (f.changes.some((c) => "aave" in c)) throw new Error("Aave changes go in an AIP file (via aip)");
    const calls: Call[] = [];
    for (const [i, c] of (f.changes as CallChange[]).entries()) calls.push(await buildCall(c, priorOf(i)));
    for (const c of calls) log.push(`  ${c.label}`);
    for (const c of calls) record.changes.push({ label: c.label, prior: freeze(c.prior) });
    if (f.via === "direct") {
      const key = f.sender ?? "emergencyGuardian";
      const sender = config.governance?.[key];
      if (!sender) throw new Error(`no governance.${key} in the config`);
      record.result = await runDirect(getAddress(sender), calls, log);
    } else if (f.via === "timelock") {
      const stepped = (f.changes as CallChange[]).findIndex((c) => c.steps);
      if (stepped >= 0) {
        if (calls.length !== 1) throw new Refused("a stepped loosening is alone in its file");
        record.result = await runSteps(f.name, calls[0]!, log);
      } else {
        record.result = await runTimelock(f.name, calls, log);
      }
    } else {
      throw new Error(`unknown via ${f.via}`);
    }
  }
  writeFileSync(join(OUT, `changes-${f.name}.json`), `${JSON.stringify(record, null, 2)}\n`);
  for (const l of log) process.stdout.write(`${l}\n`);
}

/** A step-limited loosening to a value more than one step away: one operation per step of ×LOOSEN_CAP_STEP_BPS, each run after the previous one's normal delay. */
async function runSteps(name: string, call: Call, log: string[]): Promise<Json> {
  const m = /^loosen(MarketUsdCap|TokenUsdCap|DepositorUsdCap)$/.exec(call.fn);
  if (!m) throw new Refused(`${call.fn} is not a step-limited cap loosening`);
  const cap = CAPS[m[1]!]!;
  const scope = call.args.slice(0, cap.scopeArgs);
  const target = call.args[call.args.length - 1] as bigint;
  const stepBps = BigInt(await read(STORE, parameterStoreAbi as Abi, "LOOSEN_CAP_STEP_BPS"));
  const ops: Json[] = [];
  for (let i = 0; ; i++) {
    const current = (await read(STORE, parameterStoreAbi as Abi, cap.view, scope)) as bigint;
    if (current >= target) break;
    if (i >= 64) throw new Error("more than 64 loosening steps");
    const one = (current * stepBps) / 10_000n;
    const next = one < target ? one : target;
    const args = [...scope, next];
    const stepCall: Call = { ...call, args, data: encodeFunctionData({ abi: call.abi, functionName: call.fn, args }), label: `ParameterStore.${call.fn}(${show(args).slice(1, -1)})` };
    log.push(`  step ${i + 1}: ${cap.view} ${current} -> ${next}`);
    ops.push(await runTimelock(`${name}-step${i + 1}`, [stepCall], log));
    if (!ANVIL) break;
  }
  return { steps: ops.length, operations: ops };
}

// process.exitCode, not process.exit: on Windows, exiting with the RPC client's handles open trips a libuv assertion
// (src/win/async.c) and the status becomes 127.
main().catch((e: unknown) => {
  if (e instanceof Refused) {
    process.stdout.write(`REFUSED by a limit check, nothing sent: ${e.message}\n`);
    process.exitCode = 2;
  } else if (e instanceof NotAvailable) {
    process.stdout.write(`NOT AVAILABLE: ${e.message}\n`);
    process.exitCode = 3;
  } else {
    process.stderr.write(`${(e as Error).stack ?? String(e)}\n`);
    process.exitCode = 1;
  }
});
