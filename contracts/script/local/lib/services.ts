// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The stack's services on both local chains: an rpc-recorder per chain in front of the node, one indexer (Ponder,
// PGlite, both chains), the listing content server, one local Convex deployment of services/convex with its chain
// jobs (convex-driver.ts), the keeper (both chains, signing from the keeper keystore) and the monitor. Each is a
// detached process (procs.ts): a failure later in the stack leaves the others running.
//
// STACK_CONVEX_DIR and STACK_WEBAPP_DIR point the stack at another checkout's services/convex and webapp (the webapp
// session's worktree), whose node_modules must be installed.

import { spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { CHAINS, CONTRACTS, EXPORT_KEY_ID, type LocalChain, PORTS, REPO, STACK, chainIdEnv, fallbackUrl, manifestPath, outDir, recorderUrl, rpcUrl } from "./env.ts";
import { PASSWORD_FILE, keystorePath } from "./keys.ts";
import { rpc } from "./chain.ts";
import { binJs, logPath, running, start, stop, tail, waitFor } from "./procs.ts";

export const CONVEX_DIR = process.env.STACK_CONVEX_DIR ?? join(REPO, "services/convex");
export const WEBAPP_DIR = process.env.STACK_WEBAPP_DIR ?? join(REPO, "webapp");
const INDEXER_DIR = join(REPO, "services/indexer");
export const PGLITE = join(INDEXER_DIR, ".ponder", "pglite");

/** A random value in a file only the user reads (an HMAC secret or a bearer token, never a signing key). */
export function secret(name: string, bytes = 32): string {
  mkdirSync(STACK, { recursive: true });
  const p = join(STACK, "secrets", name);
  mkdirSync(join(STACK, "secrets"), { recursive: true, mode: 0o700 });
  if (!existsSync(p)) writeFileSync(p, randomBytes(bytes).toString("base64"), { mode: 0o600 });
  return readFileSync(p, "utf8").trim();
}

const deployed = () => CHAINS.filter((c) => existsSync(manifestPath(c)));
const manifests = () => deployed().map(manifestPath).join(",");

// ─── rpc-recorders ───

/** The indexer reads each node through rpc-recorder.ts, which keeps every pinned read for a later replay. */
export async function startRecorders(): Promise<void> {
  for (const c of CHAINS) {
    const name = `recorder-${c.key}`;
    if (running(name)) continue;
    mkdirSync(join(STACK, "replay"), { recursive: true });
    start(name, process.execPath, [join(CONTRACTS, "script/e2e/rpc-recorder.ts"), String(c.recorderPort), rpcUrl(c), join(STACK, "replay", `rpc-record-${c.key}.jsonl`)]);
    await waitFor(`rpc-recorder ${c.label}`, async () => (await fetch(recorderUrl(c))).ok, 20_000, 300);
  }
}

// ─── Indexer ───

export function indexerEnv(schema: string): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {
    AVANA_MANIFEST: manifests(),
    ...chainIdEnv(),
    INDEXER_NETWORK_SET: "production",
    INDEXER_DATABASE: "pglite",
    DATABASE_SCHEMA: schema,
    PONDER_TELEMETRY_DISABLED: "true",
    INDEXER_EXPORT_KEYS: `${EXPORT_KEY_ID}:${secret("export-secret")}`,
  };
  for (const c of deployed()) {
    env[`RPC_${c.envSuffix}`] = recorderUrl(c);
    env[`RPC_${c.envSuffix}_FALLBACK`] = recorderUrl(c);
    env[`RPC_${c.envSuffix}_WS`] = rpcUrl(c).replace("http", "ws");
  }
  return env;
}

export const indexerUrl = () => `http://127.0.0.1:${PORTS.indexer}`;

/** The block each chain's checkpoint has reached, by chain ID. */
export async function indexerStatus(): Promise<Record<number, number>> {
  const j = (await (await fetch(`${indexerUrl()}/status`)).json()) as Record<string, { id: number; block: { number: number } }>;
  return Object.fromEntries(Object.values(j).map((s) => [s.id, s.block.number]));
}

const LIVE_SCHEMA_FILE = join(STACK, "indexer-schema");

/** Every file under `p`, in name order. */
function files(p: string): string[] {
  if (!statSync(p).isDirectory()) return [p];
  return readdirSync(p).sort().flatMap((f) => files(join(p, f)));
}

/**
 * An indexer schema named `<prefix>_<hash>`. Ponder resumes a schema only under the build that wrote it, and that build
 * covers the manifests its config reads, which a Hub release rewrites: the hash covers those manifests and the indexer's
 * code, so an indexer started after a release or a code change indexes into a new schema instead of refusing the old one.
 */
export function indexerSchema(prefix: string, manifestPaths: readonly string[]): string {
  const h = createHash("sha256");
  for (const p of manifestPaths) h.update(readFileSync(p));
  for (const f of ["ponder.config.ts", "ponder.schema.ts", "src"].flatMap((p) => files(join(INDEXER_DIR, p)))) h.update(readFileSync(f));
  return `${prefix}_${h.digest("hex").slice(0, 12)}`;
}

/** The live indexer's schema for the manifests deployed now. */
export const liveSchema = (): string => indexerSchema("live", deployed().map(manifestPath));

/** The schema the live indexer was last started on. */
export function runningLiveSchema(): string {
  return existsSync(LIVE_SCHEMA_FILE) ? readFileSync(LIVE_SCHEMA_FILE, "utf8").trim() : "live";
}

/** Starts the indexer on `schema` under the process name `name` (the live indexer is `indexer` on `liveSchema()`). */
export async function startIndexer(schema?: string, name = "indexer"): Promise<void> {
  if (running(name)) return;
  if (!schema) {
    schema = liveSchema();
    mkdirSync(STACK, { recursive: true });
    writeFileSync(LIVE_SCHEMA_FILE, schema);
  }
  start(name, process.execPath, [binJs("ponder"), "start", "--port", String(PORTS.indexer), "--log-format", "json"], { cwd: INDEXER_DIR, env: indexerEnv(schema) });
  await waitFor(`${name} /ready`, async () => (await fetch(`${indexerUrl()}/ready`)).ok, 900_000, 2_000).catch((e) => {
    throw new Error(`${(e as Error).message}\n${tail(name, 15)}`);
  });
}

/** Waits until the indexer's checkpoint reaches each chain's current head (interval mining brings new blocks). */
export async function indexerAtHead(timeoutMs = 600_000): Promise<Record<number, number>> {
  const heads = Object.fromEntries(await Promise.all(deployed().map(async (c) => [c.chainId, Number(BigInt(await rpc<string>(rpcUrl(c), "eth_blockNumber")))] as const)));
  return waitFor("indexer at the chains' heads", async () => {
    const s = await indexerStatus();
    return Object.entries(heads).every(([id, h]) => (s[Number(id)] ?? 0) >= h) ? s : undefined;
  }, timeoutMs, 3_000);
}

// ─── Listing content ───

export async function startContent(): Promise<void> {
  if (running("content")) return;
  start("content", process.execPath, [join(CONTRACTS, "script/local/content-server.ts"), String(PORTS.content)]);
  await waitFor("listing content server", async () => (await fetch(`http://127.0.0.1:${PORTS.content}/x`)).status === 404, 10_000, 300);
}

// ─── Convex ───

export interface ConvexInfo {
  readonly url: string;
  readonly siteUrl: string | undefined;
  readonly adminKey: string;
  readonly dir: string;
}
const convexInfoPath = join(STACK, "convex.json");
export const convexInfo = (): ConvexInfo | undefined => (existsSync(convexInfoPath) ? (JSON.parse(readFileSync(convexInfoPath, "utf8")) as ConvexInfo) : undefined);

/** The anonymous local deployment's URL and admin key, from the files `convex dev` writes in `dir`. */
export function discoverConvex(dir = CONVEX_DIR): ConvexInfo | undefined {
  // `convex dev` keeps the local deployment's ports and admin key here (replay-check.ts reads the same file).
  const local = join(dir, ".convex", "local", "default", "config.json");
  if (existsSync(local)) {
    const j = JSON.parse(readFileSync(local, "utf8")) as { adminKey?: string; ports?: { cloud?: number; site?: number } };
    if (j.adminKey && j.ports?.cloud) return { url: `http://127.0.0.1:${j.ports.cloud}`, siteUrl: j.ports.site ? `http://127.0.0.1:${j.ports.site}` : undefined, adminKey: j.adminKey, dir: dir };
  }
  const envLocal = join(dir, ".env.local");
  if (!existsSync(envLocal)) return undefined;
  const vars = Object.fromEntries(readFileSync(envLocal, "utf8").split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1).replace(/^"|"$/g, "").replace(/\s+#.*$/, "")]));
  const url = vars.CONVEX_URL;
  const deployment = (vars.CONVEX_DEPLOYMENT ?? "").replace(/^[a-z]+:/, "").replace(/\s.*$/, "");
  if (!url || !deployment) return undefined;
  const roots = [join(dir, ".convex", "local", "default"), join(homedir(), ".convex", "anonymous-convex-backend-state", deployment), join(homedir(), ".convex", "convex-backend-state", deployment)];
  for (const r of roots) {
    const cfg = join(r, "config.json");
    if (!existsSync(cfg)) continue;
    const j = JSON.parse(readFileSync(cfg, "utf8")) as { adminKey?: string };
    if (j.adminKey) return { url, siteUrl: vars.CONVEX_SITE_URL, adminKey: j.adminKey, dir: dir };
  }
  return undefined;
}

export async function convexCall(info: ConvexInfo, kind: "query" | "mutation" | "action", path: string, args: Record<string, unknown>): Promise<unknown> {
  const r = await fetch(`${info.url}/api/${kind}`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Convex ${info.adminKey}` },
    body: JSON.stringify({ path, args, format: "json" }),
  });
  const j = (await r.json()) as { status: string; value?: unknown; errorMessage?: string };
  if (j.status !== "success") throw new Error(`${path}: ${j.errorMessage ?? r.status}`);
  return j.value;
}
export const convex = (kind: "query" | "mutation" | "action", path: string, args: Record<string, unknown> = {}) => {
  const info = convexInfo();
  if (!info) throw new Error("no local Convex deployment: run the stack's up command");
  return convexCall(info, kind, path, args);
};

/** Sets deployment environment variables through the deployment's admin API (no value on a command line). */
export async function convexEnv(info: ConvexInfo, vars: Record<string, string>): Promise<void> {
  const r = await fetch(`${info.url}/api/update_environment_variables`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Convex ${info.adminKey}` },
    body: JSON.stringify({ changes: Object.entries(vars).map(([name, value]) => ({ name, value })) }),
  });
  if (!r.ok) throw new Error(`convex environment: HTTP ${r.status} ${await r.text()}`);
}

/** Files `convex dev` needs that a checkout may lack; made by the stack and removed by `stopConvex`. */
const CONVEX_MADE = join(STACK, "convex-made.json");

/**
 * Starts `convex dev` on an anonymous local deployment (no account, nothing leaves the machine), sets its environment
 * (the chains' RPCs, the indexer export, the listing content, the session secret) and writes each chain's
 * `deployments` row from its manifest.
 */
export async function startConvex(): Promise<ConvexInfo> {
  if (!running("convex")) {
    const made = [".gitignore", "convex/tsconfig.json"].map((f) => join(CONVEX_DIR, f)).filter((f) => !existsSync(f));
    writeFileSync(CONVEX_MADE, JSON.stringify(made));
    rmSync(logPath("convex"), { force: true });
    start("convex", process.execPath, [binJs("convex"), "dev", "--codegen", "disable", "--typecheck", "disable", "--tail-logs", "always"], {
      cwd: CONVEX_DIR,
      env: { CONVEX_AGENT_MODE: "anonymous" },
    });
  }
  const log = () => (existsSync(logPath("convex")) ? readFileSync(logPath("convex"), "utf8") : "");
  const info = await waitFor("Convex local deployment", async () => discoverConvex(), 180_000, 2_000).catch((e) => {
    throw new Error(`${(e as Error).message}\n${tail("convex", 20)}`);
  });
  writeFileSync(convexInfoPath, `${JSON.stringify(info, null, 2)}\n`, { mode: 0o600 });
  const vars: Record<string, string> = {
    SIWE_JWT_ISSUER: `http://127.0.0.1:${PORTS.webapp}`,
    INDEXER_EXPORT_URL: indexerUrl(),
    INDEXER_EXPORT_KEY_ID: EXPORT_KEY_ID,
    INDEXER_EXPORT_SECRET: secret("export-secret"),
    LISTING_CONTENT_URL: `http://127.0.0.1:${PORTS.content}`,
    CONVEX_SESSION_SECRET: secret("convex-session-secret", 48),
    ...chainIdEnv(),
  };
  for (const c of CHAINS) {
    vars[`RPC_${c.envSuffix}`] = rpcUrl(c);
    vars[`RPC_${c.envSuffix}_FALLBACK`] = fallbackUrl(c);
  }
  // The backend answers a moment after its config is written: retry until it takes the variables.
  await waitFor("Convex environment", async () => {
    await convexEnv(info, vars);
    return true;
  }, 120_000, 2_000);
  // The auth config needs SIWE_JWT_ISSUER before the CLI pushes: touch it so `convex dev` pushes again once it is set.
  if (!/Convex functions ready/.test(log())) {
    const auth = join(CONVEX_DIR, "convex", "auth.config.ts");
    if (existsSync(auth)) writeFileSync(auth, readFileSync(auth));
  }
  await waitFor("Convex functions pushed", async () => /Convex functions ready/.test(log()), 300_000, 2_000).catch((e) => {
    throw new Error(`${(e as Error).message}\n${tail("convex", 20)}`);
  });
  for (const c of deployed()) {
    const row = await deploymentRow(c);
    try {
      await convex("mutation", "deployments:setDeployment", row);
    } catch (e) {
      // A Convex checkout from before the About-card and swap fields takes the row without them.
      if (!/ArgumentValidationError|extra field/i.test((e as Error).message)) throw e;
      const { lpVaults: _l, riskModule: _r, spokeOracles: _o, external: _x, ...base } = row;
      await convex("mutation", "deployments:setDeployment", base);
    }
  }
  return info;
}

/** ORACLE() of an Aave V4 Spoke. */
const ORACLE = "0x38013f02";

/** The chain's `deployments` row, from its release manifest (as replay-check.ts writes it), with each Spoke's oracle
 * read on chain (the manifest does not carry it). */
export async function deploymentRow(c: LocalChain): Promise<Record<string, unknown>> {
  const m = JSON.parse(readFileSync(manifestPath(c), "utf8")) as Record<string, any>;
  const world = JSON.parse(readFileSync(join(outDir(c), "world.json"), "utf8")) as Record<string, any>;
  return deploymentRowFrom(c.chainId, m, world, await spokeOracles(rpcUrl(c), m), rpcUrl(c));
}

/** Each Lend and CDP Spoke of manifest `m` with its oracle (ORACLE()), read over `url`; a Spoke without one is left out. */
export async function spokeOracles(url: string, m: Record<string, any>): Promise<{ spoke: string; oracle: string }[]> {
  const out: { spoke: string; oracle: string }[] = [];
  for (const spoke of [...m.aave.lendSpokes, ...m.aave.borrowSpokes].map((s: Record<string, any>) => s.address as string)) {
    const r = await rpc<string>(url, "eth_call", [{ to: spoke, data: ORACLE }, "latest"]);
    const oracle = `0x${r.slice(-40)}`;
    if (!/^0x0{40}$/.test(oracle)) out.push({ spoke, oracle });
  }
  return out;
}

/** A chain's `deployments` row from its manifest `m`, its world file, its Spokes' oracles and its explorer. */
export function deploymentRowFrom(chainId: number, m: Record<string, any>, world: Record<string, any>, spokeOracles: { spoke: string; oracle: string }[], explorerUrl: string): Record<string, unknown> {
  const lendSpokes = m.aave.lendSpokes.map((s: Record<string, any>) => s.address as string);
  const cdpSpokes = m.aave.borrowSpokes.map((s: Record<string, any>) => s.address as string);
  return {
    chainId,
    lens: m.avana.lens.address,
    hubs: m.aave.hubs.map((h: Record<string, any>) => ({ address: h.address, label: h.label, tier: h.tier })),
    lendSpokes,
    cdpSpokes,
    firstLossReserves: m.avana.firstLossReserves.map((r: Record<string, any>) => ({ address: r.address, asset: r.asset, hub: r.hub })),
    marketRegistry: m.avana.marketRegistry.address,
    timelock: m.avana.timelock.address,
    explorerUrl,
    nativeUsdFeed: world.feeds.WETH.primary,
    release: m.release,
    // The About card's contract rows and the swap venues (optional in Convex; a slot without an address is left out).
    lpVaults: (m.avana.lpVaults ?? []).filter((v: Record<string, any>) => v.address).map((v: Record<string, any>) => ({ integrationId: v.integrationId, address: v.address })),
    ...(m.avana.riskModule?.address ? { riskModule: m.avana.riskModule.address } : {}),
    spokeOracles,
    external: (m.external ?? []).filter((x: Record<string, any>) => x.address).map((x: Record<string, any>) => ({ group: x.group, name: x.name, address: x.address, standIn: x.standIn })),
  };
}

export function stopConvex(): void {
  stop("convex-driver");
  stop("convex");
  if (existsSync(CONVEX_MADE)) for (const f of JSON.parse(readFileSync(CONVEX_MADE, "utf8")) as string[]) rmSync(f, { force: true });
}

export function startConvexDriver(): void {
  if (!running("convex-driver")) start("convex-driver", process.execPath, [join(CONTRACTS, "script/local/convex-driver.ts")]);
}

// ─── Keeper and monitor ───

function tls(): { cert: string; key: string } {
  const dir = join(STACK, "keeper-tls");
  const cert = join(dir, "cert.pem");
  const key = join(dir, "key.pem");
  if (!existsSync(cert)) {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    const r = spawnSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30", "-subj", "/CN=localhost", "-keyout", key, "-out", cert], {
      encoding: "utf8",
      env: { ...process.env, MSYS2_ARG_CONV_EXCL: "/CN=" },
    });
    if (r.status !== 0) throw new Error(`openssl: ${r.stderr}`);
  }
  return { cert, key };
}

/** The keeper in active mode on every deployed chain, signing from the keeper keystore, reporting to the monitor. */
export async function startKeeper(): Promise<void> {
  if (running("keeper")) return;
  const t = tls();
  mkdirSync(join(STACK, "keeper"), { recursive: true });
  const env: NodeJS.ProcessEnv = {
    AVANA_MANIFEST: manifests(),
    ...chainIdEnv(),
    KEEPER_NETWORK_SET: "production",
    KEEPER_MODE: "active",
    KEEPER_ROLE: "primary",
    KEEPER_SHARD: "0",
    KEEPER_SHARD_COUNT: "1",
    KEEPER_KILL_SWITCH_PORT: String(PORTS.keeperKill),
    KEEPER_KILL_SWITCH_TLS_CERT: t.cert,
    KEEPER_KILL_SWITCH_TLS_KEY: t.key,
    KEEPER_KILL_SWITCH_CLIENT_CA: t.cert,
    KEEPER_HALT_STATE_PATH: join(STACK, "keeper", "halt"),
    KEEPER_METRICS_PORT: String(PORTS.keeperMetrics),
    KEEPER_INDEXER_URL: indexerUrl(),
    KEEPER_INDEXER_KEY: `${EXPORT_KEY_ID}:${secret("export-secret")}`,
    KEEPER_LOCAL_KEYSTORE_PASSWORD_FILE: PASSWORD_FILE,
    KEEPER_MONITOR_URL: `http://127.0.0.1:${PORTS.monitor}`,
  };
  for (const c of deployed()) {
    env[`RPC_${c.envSuffix}`] = rpcUrl(c);
    env[`RPC_${c.envSuffix}_FALLBACK`] = fallbackUrl(c);
    env[`RPC_${c.envSuffix}_WS`] = rpcUrl(c).replace("http", "ws");
    env[`RPC_${c.envSuffix}_PRIVATE`] = rpcUrl(c);
    env[`KEEPER_LOCAL_KEYSTORE_${c.envSuffix}`] = keystorePath("keeper");
    env[`KEEPER_GAS_CEILING_WEI_${c.envSuffix}`] = "1000000000000000000";
    // The expected daily gas spend D (docs/keeper-gas.md): a local figure, 0.1 ETH; the budgets and warnings follow it.
    env[`KEEPER_GAS_DAILY_SPEND_WEI_${c.envSuffix}`] = "100000000000000000";
    env[`KEEPER_MONITOR_INSTANCE_${c.envSuffix}`] = `keeper-${c.key}`;
    env[`KEEPER_MONITOR_TOKEN_${c.envSuffix}`] = secret(`keeper-token-${c.key}`);
  }
  start("keeper", process.execPath, [binJs("tsx"), "src/main.ts"], { cwd: join(REPO, "services/keeper"), env });
  await waitFor("keeper metrics", async () => (await fetch(`http://127.0.0.1:${PORTS.keeperMetrics}/metrics`)).ok, 90_000, 2_000).catch((e) => {
    throw new Error(`${(e as Error).message}\n${tail("keeper", 20)}`);
  });
}

const RECIPIENTS = ["onCall", "governanceSafeSigners", "emergencyGuardianSigners", "aaveProtocolGuardian", "operators", "emergencyGuardian", "guardians", "riskProviders", "governance", "standbyKeeper", "keeperOnCall", "avanaLabs", "aaveDao", "aave", "coverageRole", "engineering", "cancellers", "signers"];

/** The monitor on every deployed chain; every recipient is routed to the log channel (STACK/logs/monitor.log). */
export async function startMonitor(): Promise<void> {
  if (running("monitor")) return;
  mkdirSync(join(STACK, "monitor"), { recursive: true });
  const env: NodeJS.ProcessEnv = {
    AVANA_MANIFEST: manifests(),
    ...chainIdEnv(),
    MONITOR_NETWORK_SET: "production",
    MONITOR_CHANNELS: "log:log",
    MONITOR_KEEPER_INSTANCES: deployed().map((c) => `keeper-${c.key}:${c.key}`).join(","),
    MONITOR_STATUS_TOKEN: secret("monitor-status-token"),
    MONITOR_INCIDENT_LOG: join(STACK, "monitor", "incidents.jsonl"),
    MONITOR_STATE_PATH: join(STACK, "monitor", "state.json"),
    MONITOR_PORT: String(PORTS.monitor),
  };
  for (const r of RECIPIENTS) env[`MONITOR_ROUTE_${r.replace(/[A-Z]/g, (x) => `_${x}`).toUpperCase()}`] = "log";
  for (const c of deployed()) {
    env[`RPC_${c.envSuffix}`] = rpcUrl(c);
    env[`RPC_${c.envSuffix}_FALLBACK`] = fallbackUrl(c);
    env[`MONITOR_KEEPER_TOKEN_KEEPER_${c.key.replace(/[^A-Za-z0-9]/g, "_").toUpperCase()}`] = secret(`keeper-token-${c.key}`);
  }
  start("monitor", process.execPath, [binJs("tsx"), "src/main.ts"], { cwd: join(REPO, "services/monitor"), env });
  await waitFor("monitor", async () => (await fetch(`http://127.0.0.1:${PORTS.monitor}/v1/status`, { headers: { authorization: `Bearer ${secret("monitor-status-token")}` } })).ok, 90_000, 2_000).catch((e) => {
    throw new Error(`${(e as Error).message}\n${tail("monitor", 20)}`);
  });
}

/** The faucet on every deployed chain (fork mode: cheatcodes, no key), its tokens and prices from each manifest. */
export async function startFaucet(): Promise<void> {
  if (running("faucet")) return;
  const env: NodeJS.ProcessEnv = {
    FAUCET_CHAIN_KIND: "fork",
    FAUCET_CHAIN_IDS: CHAINS.map((c) => c.chainId).join(","),
    FAUCET_PORT: String(PORTS.faucet),
    FAUCET_DATA_DIR: join(STACK, "faucet"),
  };
  for (const c of deployed()) {
    env[`FAUCET_RPC_${c.network.toUpperCase()}`] = rpcUrl(c);
    env[`FAUCET_MANIFEST_${c.network.toUpperCase()}`] = manifestPath(c);
  }
  start("faucet", process.execPath, [binJs("tsx"), "src/main.ts"], { cwd: join(REPO, "services/faucet"), env });
  await waitFor("faucet", async () => (await fetch(`${faucetUrl()}/healthz`)).ok, 90_000, 2_000).catch((e) => {
    throw new Error(`${(e as Error).message}\n${tail("faucet", 20)}`);
  });
}

export const faucetUrl = () => `http://127.0.0.1:${PORTS.faucet}`;

/** Every service process the stack starts, in stopping order. */
export const SERVICE_NAMES = ["webapp", "faucet", ...CHAINS.map((c) => `activity-${c.key}`), "keeper", "monitor", "convex-driver", "convex", "content", "indexer", ...CHAINS.map((c) => `recorder-${c.key}`)];

export function stopServices(): string[] {
  const stopped: string[] = [];
  for (const n of SERVICE_NAMES) {
    if (n === "convex") {
      if (running("convex")) stopped.push("convex");
      stopConvex();
    } else if (stop(n)) stopped.push(n);
  }
  return stopped;
}

