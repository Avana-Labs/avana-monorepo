// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The webapp and its services on the public test networks (Sepolia 11155111, Base Sepolia 84532), as the local stack
// (script/local/stack.ts) runs them on its anvil chains: an RPC proxy per network, the indexer (Ponder, PGlite), the
// listing content server, a local Convex deployment of services/convex, the monitor, the keeper, the faucet (minting the
// test tokens from the deployer keystore) and the webapp on http://127.0.0.1:3100, all reading the networks' release
// manifests that script/testnet/testnet.ts wrote.
//
// Usage, from contracts/:
//   node script/testnet/app.ts up [--chains sepolia,base-sepolia] [--deployments <dir>] [--gas-eth <eth>] [--no-webapp]
//   node script/testnet/app.ts status
//   node script/testnet/app.ts down
//
// Inputs, none in the repository:
// - The deploy outputs: <dir>/<network>/manifest.json and world.json (--deployments, default this checkout's
//   contracts/deployments-local; point it at the checkout that ran the deploy).
// - SEPOLIA_RPC_URL, BASE_SEPOLIA_RPC_URL: the environment, else the deploying checkout's encrypted secrets
//   (<dir>/stack/keystore/secrets.enc, `stack.ts secrets`). Optional SEPOLIA_WS_URL, BASE_SEPOLIA_WS_URL when the
//   provider's WebSocket endpoint is not the https URL as wss.
// - AVANA_TESTNET_CONFIG: the private test-network config file; the faucet signs with its DEPLOYER keystore, the test
//   tokens' minter.
// - Optional KEEPER_KMS_KEY_ID_SEPOLIA, KEEPER_KMS_KEY_ID_BASE_SEPOLIA (and AWS credentials): an active keeper there;
//   without them the keeper observes.
// The RPC URLs reach only the proxies' environment; every line this command prints is redacted.
//
// Its processes, logs and stores are in contracts/deployments-local/testnet-app/ (logs/<process>.log, app.env lists the
// endpoints, indexer-schema the indexer's schema). `up` resumes: a running process is kept, except an indexer whose
// manifests or code changed since it started (a Hub release), which starts again on a new schema. APP_PORT_<NAME> moves a port (plan.ts appPorts);
// APP_CONVEX_DIR and APP_WEBAPP_DIR run another checkout's services/convex and webapp.

import { spawnSync } from "node:child_process";
import { generateKeyPairSync, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  type AppChain,
  type AppSecrets,
  type Plan,
  APP_CHAINS,
  appPorts,
  checkOutputs,
  convexVars,
  faucetEnv,
  faucetSignerOf,
  faucetUrl,
  indexerEnv,
  indexerSchema,
  indexerSchemaFile,
  indexerUrl,
  keeperEnv,
  manifestOf,
  manifestPathsOf,
  monitorEnv,
  outDirOf,
  parseConfigFile,
  proxyEnv,
  proxyUrl,
  redact,
  selectChains,
  webappEnv,
  webappUrl,
} from "./app/plan.ts";

const CONTRACTS = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const REPO = resolve(CONTRACTS, "..");
const RUN = join(CONTRACTS, "deployments-local", "testnet-app");
// The local stack's process records stay its own: this app's are in RUN (env.ts STACK_RUN_DIR), set before procs.ts loads.
process.env.STACK_RUN_DIR = RUN;
const { alive, binJs, logPath, names, record, running, start, stop, tail, waitFor } = await import("../local/lib/procs.ts");
const { convexCall, convexEnv, deploymentRowFrom, discoverConvex, spokeOracles } = await import("../local/lib/services.ts");

const CONVEX_DIR = process.env.APP_CONVEX_DIR ?? join(REPO, "services/convex");
const WEBAPP_DIR = process.env.APP_WEBAPP_DIR ?? join(REPO, "webapp");
const INDEXER_DIR = join(REPO, "services/indexer");
const LOCAL_STACK = join(CONTRACTS, "deployments-local", "stack");

const argv = process.argv.slice(2);
const flag = (n: string) => argv.includes(`--${n}`);
const opt = (n: string) => {
  const i = argv.indexOf(`--${n}`);
  return i === -1 ? undefined : argv[i + 1];
};

/** Every secret value this run holds, by name: each printed line passes through `redact`. */
const SECRETS: Record<string, string | undefined> = {};
const say = (s: string) => process.stdout.write(`${redact(s, SECRETS)}\n`);
class Stop extends Error {}

/** A random value in RUN/secrets/<name>, made once, read only by the user (a bearer token or HMAC secret, not a key of
 * any chain). */
function runSecret(name: string, make: () => string = () => randomBytes(32).toString("base64")): string {
  const dir = join(RUN, "secrets");
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const p = join(dir, name);
  if (!existsSync(p)) writeFileSync(p, make(), { mode: 0o600 });
  return readFileSync(p, "utf8").trim();
}

/** The webapp's session-signing key (RS256 JWK), made once in RUN/secrets, as the webapp's `.env.local` holds one. */
const siweJwk = () =>
  runSecret("siwe-jwk.json", () => JSON.stringify({ ...generateKeyPairSync("rsa", { modulusLength: 2048 }).privateKey.export({ format: "jwk" }), kid: `testnet-app-${randomBytes(4).toString("hex")}` }));

function appSecrets(chains: readonly AppChain[]): AppSecrets {
  return {
    exportSecret: runSecret("export-secret"),
    monitorStatusToken: runSecret("monitor-status-token"),
    keeperTokens: Object.fromEntries(chains.map((c) => [c.serviceKey, runSecret(`keeper-token-${c.serviceKey}`)])),
    sessionSecret: runSecret("convex-session-secret"),
    rateLimitSecret: runSecret("rate-limit-secret"),
    siweJwk: siweJwk(),
  };
}

/** The network's RPC URL (and optional WebSocket URL): the environment, else the deploying checkout's encrypted secrets. */
async function rpcSecrets(deployments: string, chains: readonly AppChain[]): Promise<Record<string, { http: string; ws?: string }>> {
  const { readSecretsFile } = await import("../local/lib/secrets.ts");
  const keystore = join(deployments, "stack", "keystore");
  let stored: Record<string, string> | undefined;
  const value = (name: string): string | undefined => {
    const env = process.env[name]?.trim();
    if (env) return env;
    stored ??= readSecretsFile(join(keystore, "secrets.enc"), join(keystore, "password"));
    return stored[name]?.trim() || undefined;
  };
  const out: Record<string, { http: string; ws?: string }> = {};
  for (const c of chains) {
    const http = value(c.rpcSecret);
    if (!http) throw new Stop(`${c.rpcSecret} is not set, in the environment or the encrypted secrets of ${keystore}`);
    const wsName = c.rpcSecret.replace("_RPC_URL", "_WS_URL");
    const ws = value(wsName);
    SECRETS[c.rpcSecret] = http;
    if (ws) SECRETS[wsName] = ws;
    out[c.network] = { http, ws };
  }
  // Every process inherits this environment: from here on the URLs reach the proxies only, in their own environment.
  for (const c of APP_CHAINS) for (const n of [c.rpcSecret, c.rpcSecret.replace("_RPC_URL", "_WS_URL")]) delete process.env[n];
  return out;
}

async function rpc<T>(url: string, method: string, params: unknown[] = []): Promise<T> {
  const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  const j = (await r.json()) as { result?: T; error?: { message: string } };
  if (j.error) throw new Error(j.error.message);
  return j.result as T;
}

/** A process of the local stack's, still running in this checkout (a second indexer or Convex on one store refuses). */
function localStackRuns(name: string): boolean {
  const p = join(LOCAL_STACK, "pids", `${name}.json`);
  if (!existsSync(p)) return false;
  return alive((JSON.parse(readFileSync(p, "utf8")) as { pid: number }).pid);
}

const failed = (name: string) => (e: unknown) => {
  throw new Error(`${(e as Error).message}\n${tail(name, 20)}`);
};

async function startProxies(plan: Plan, urls: Record<string, { http: string; ws?: string }>): Promise<void> {
  const origins = [webappUrl(plan.ports), `http://localhost:${plan.ports.webapp}`];
  for (const c of plan.chains) {
    const name = `proxy-${c.network}`;
    if (!running(name)) {
      const env = { ...proxyEnv(urls[c.network]!.http, origins), ...(urls[c.network]!.ws ? { PROXY_WS_UPSTREAM: urls[c.network]!.ws! } : {}) };
      start(name, process.execPath, [join(CONTRACTS, "script/testnet/rpc-proxy.ts"), String(plan.ports.proxy[c.network])], { env });
    }
    const id = await waitFor(`${c.label} RPC`, async () => Number(BigInt(await rpc<string>(proxyUrl(plan.ports, c), "eth_chainId"))), 60_000, 1_000).catch(failed(name));
    if (id !== c.chainId) throw new Stop(`${c.rpcSecret} answers chain ${id}, not ${c.label} (${c.chainId})`);
    say(`${c.label}: RPC proxy on ${proxyUrl(plan.ports, c)}, block ${Number(BigInt(await rpc<string>(proxyUrl(plan.ports, c), "eth_blockNumber")))}`);
  }
}

/**
 * The indexer on the schema of the current manifests and code (plan.ts indexerSchema), recorded in RUN/indexer-schema.
 * A running indexer on that schema is kept; one on an older schema (a Hub release rewrote a manifest, or the code
 * changed) is stopped and the new schema indexes every block again from each release's first block.
 */
async function startIndexer(plan: Plan): Promise<void> {
  const schema = indexerSchema(INDEXER_DIR, manifestPathsOf(plan));
  const file = indexerSchemaFile(RUN);
  const previous = existsSync(file) ? readFileSync(file, "utf8").trim() : undefined;
  if (running("indexer")) {
    if (previous === schema) return;
    stop("indexer");
    say(`indexer: the manifests or the indexer code changed, so schema ${schema} replaces ${previous ?? "the earlier one"} (a full reindex)`);
  } else if (previous && previous !== schema) say(`indexer: schema ${schema} replaces ${previous} (the manifests or the indexer code changed; a full reindex)`);
  if (localStackRuns("indexer")) throw new Stop("the local stack's indexer runs in this checkout, on the same PGlite store: run the app from another checkout or stop the stack");
  writeFileSync(file, `${schema}\n`);
  start("indexer", process.execPath, [binJs("ponder"), "start", "--port", String(plan.ports.indexer), "--log-format", "json"], { cwd: INDEXER_DIR, env: indexerEnv(plan, schema) });
  await waitFor("indexer /ready (it backfills from each release's first block)", async () => (await fetch(`${indexerUrl(plan.ports)}/ready`)).ok, 1_800_000, 5_000).catch(failed("indexer"));
}

async function startContent(plan: Plan): Promise<void> {
  if (running("content")) return;
  start("content", process.execPath, [join(CONTRACTS, "script/local/content-server.ts"), String(plan.ports.content)], {
    env: { CONTENT_DIRS: plan.chains.map((c) => outDirOf(plan.deployments, c)).join(delimiter) },
  });
  await waitFor("listing content server", async () => (await fetch(`http://127.0.0.1:${plan.ports.content}/x`)).status === 404, 10_000, 300);
}

/** Pushes counted in the Convex log. */
const pushes = () => (existsSync(logPath("convex")) ? (readFileSync(logPath("convex"), "utf8").match(/Convex functions ready/g) ?? []).length : 0);

/**
 * `convex dev` on an anonymous local deployment of CONVEX_DIR, its environment set (the proxies, AVANA_CHAIN_IDS, the
 * indexer export, the session secrets), pushed again so crons.ts and auth.config.ts read it, and each chain's
 * `deployments` row written from its manifest.
 */
async function startConvex(plan: Plan): Promise<{ url: string; siteUrl: string | undefined }> {
  if (!running("convex")) {
    if (localStackRuns("convex") && resolve(CONVEX_DIR) === resolve(join(REPO, "services/convex"))) {
      throw new Stop("the local stack's Convex runs on this checkout's services/convex: set APP_CONVEX_DIR to another checkout's, or run the app from another checkout");
    }
    start("convex", process.execPath, [binJs("convex"), "dev", "--codegen", "disable", "--typecheck", "disable", "--tail-logs", "always"], {
      cwd: CONVEX_DIR,
      env: { CONVEX_AGENT_MODE: "anonymous" },
    });
  }
  const info = await waitFor("Convex local deployment", async () => discoverConvex(CONVEX_DIR), 180_000, 2_000).catch(failed("convex"));
  writeFileSync(join(RUN, "convex.json"), `${JSON.stringify(info, null, 2)}\n`, { mode: 0o600 });
  await waitFor("Convex environment", async () => {
    await convexEnv(info, convexVars(plan));
    return true;
  }, 120_000, 2_000);
  const before = pushes();
  for (const f of ["crons.ts", "auth.config.ts"]) {
    const p = join(CONVEX_DIR, "convex", f);
    writeFileSync(p, readFileSync(p));
  }
  await waitFor("Convex functions pushed with the test networks' environment", async () => pushes() > before, 300_000, 2_000).catch(failed("convex"));
  for (const c of plan.chains) {
    const m = JSON.parse(readFileSync(manifestOf(plan.deployments, c), "utf8")) as Record<string, any>;
    const world = JSON.parse(readFileSync(join(outDirOf(plan.deployments, c), "world.json"), "utf8")) as Record<string, any>;
    const row = deploymentRowFrom(c.chainId, m, world, await spokeOracles(proxyUrl(plan.ports, c), m), c.explorerUrl);
    await convexCall(info, "mutation", "deployments:setDeployment", row);
  }
  return info;
}

function tls(): { cert: string; key: string } {
  const dir = join(RUN, "keeper-tls");
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

async function startMonitor(plan: Plan): Promise<void> {
  if (running("monitor")) return;
  mkdirSync(join(RUN, "monitor"), { recursive: true });
  start("monitor", process.execPath, [binJs("tsx"), "src/main.ts"], { cwd: join(REPO, "services/monitor"), env: monitorEnv(plan) });
  await waitFor("monitor", async () => (await fetch(`http://127.0.0.1:${plan.ports.monitor}/v1/status`, { headers: { authorization: `Bearer ${plan.secrets.monitorStatusToken}` } })).ok, 90_000, 2_000).catch(failed("monitor"));
}

async function startKeeper(plan: Plan): Promise<string> {
  const env = keeperEnv(plan, tls(), process.env);
  if (!running("keeper")) {
    mkdirSync(join(RUN, "keeper"), { recursive: true });
    start("keeper", process.execPath, [binJs("tsx"), "src/main.ts"], { cwd: join(REPO, "services/keeper"), env });
    await waitFor("keeper metrics", async () => (await fetch(`http://127.0.0.1:${plan.ports.keeperMetrics}/metrics`)).ok, 90_000, 2_000).catch(failed("keeper"));
  }
  return env.KEEPER_MODE!;
}

async function startFaucet(plan: Plan, gasEth: string): Promise<string> {
  const path = process.env.AVANA_TESTNET_CONFIG;
  if (!path || !existsSync(path)) throw new Stop("AVANA_TESTNET_CONFIG does not name the private test-network config file (the faucet signs with its DEPLOYER keystore)");
  const signer = faucetSignerOf(parseConfigFile(readFileSync(path, "utf8")));
  if (!existsSync(signer.keystore) || !existsSync(signer.passwordFile)) throw new Stop("the config file's DEPLOYER keystore or PASSWORD_FILE does not exist");
  const r = spawnSync("cast", ["wallet", "address", "--keystore", signer.keystore, "--password-file", signer.passwordFile], { encoding: "utf8" });
  if (r.status !== 0) throw new Stop("the DEPLOYER keystore did not open with the password file");
  const minter = r.stdout.trim();
  for (const c of plan.chains) {
    const deployer = (JSON.parse(readFileSync(manifestOf(plan.deployments, c), "utf8")) as { deployer?: string }).deployer;
    if (deployer && deployer.toLowerCase() !== minter.toLowerCase()) throw new Stop(`${c.label}: the manifest's deployer is ${deployer}, not the DEPLOYER keystore's ${minter}: the faucet could not mint its test tokens`);
  }
  if (!running("faucet")) {
    start("faucet", process.execPath, [binJs("tsx"), "src/main.ts"], { cwd: join(REPO, "services/faucet"), env: faucetEnv(plan, signer, gasEth) });
    await waitFor("faucet", async () => (await fetch(`${faucetUrl(plan.ports)}/healthz`)).ok, 90_000, 2_000).catch(failed("faucet"));
  }
  return minter;
}

function startWebapp(plan: Plan, convex: { url: string; siteUrl: string | undefined }): void {
  if (running("webapp")) return;
  start("webapp", process.execPath, [join(WEBAPP_DIR, "scripts", "run-next.mjs"), "dev", "--port", String(plan.ports.webapp), "--hostname", "127.0.0.1"], {
    cwd: WEBAPP_DIR,
    env: webappEnv(plan, convex),
  });
}

function writeEnvFile(plan: Plan, convex: { url: string; siteUrl: string | undefined }): void {
  const lines = [
    "# Written by contracts/script/testnet/app.ts: the test-network app's endpoints. No secret, key or RPC URL is listed here.",
    `APP_WEBAPP_URL=${webappUrl(plan.ports)}`,
    `APP_CONVEX_URL=${convex.url}`,
    `APP_CONVEX_SITE_URL=${convex.siteUrl ?? ""}`,
    `APP_INDEXER_URL=${indexerUrl(plan.ports)}`,
    `APP_FAUCET_URL=${faucetUrl(plan.ports)}`,
    `APP_CHAIN_IDS=${plan.chains.map((c) => c.chainId).join(",")}`,
  ];
  for (const c of plan.chains) lines.push(`APP_RPC_PROXY_${c.chainId}=${proxyUrl(plan.ports, c)}`, `APP_MANIFEST_${c.chainId}=${manifestOf(plan.deployments, c)}`);
  writeFileSync(join(RUN, "app.env"), `${lines.join("\n")}\n`);
}

async function up(): Promise<void> {
  const chains = selectChains(opt("chains"));
  const deployments = resolve(opt("deployments") ?? join(CONTRACTS, "deployments-local"));
  const gasEth = opt("gas-eth") ?? "0";
  const errors = checkOutputs(deployments, chains);
  if (errors.length) throw new Stop(`the deploy outputs are not ready:\n  ${errors.join("\n  ")}`);
  mkdirSync(RUN, { recursive: true });
  const urls = await rpcSecrets(deployments, chains);
  const plan: Plan = { chains, ports: appPorts(process.env), deployments, run: RUN, secrets: appSecrets(chains) };
  say(`test-network app: ${chains.map((c) => `${c.label} (${c.chainId})`).join(", ")}; deploy outputs in ${deployments}`);
  await startProxies(plan, urls);
  await startIndexer(plan);
  say(`indexer: ready on ${indexerUrl(plan.ports)}`);
  await startContent(plan);
  const convex = await startConvex(plan);
  say(`convex: ${convex.url} (functions from ${CONVEX_DIR}, crons on ${plan.chains.map((c) => c.chainId).join(", ")})`);
  await startMonitor(plan);
  say(`monitor: running on port ${plan.ports.monitor}`);
  const mode = await startKeeper(plan);
  say(`keeper: ${mode === "active" ? "active where a KMS key is set" : "observing (no KEEPER_KMS_KEY_ID_<CHAIN> set)"}`);
  const minter = await startFaucet(plan, gasEth);
  say(`faucet: ready on ${faucetUrl(plan.ports)}, minting from the deployer ${minter}${gasEth !== "0" ? `, topping wallets up to ${gasEth} ETH` : ""}`);
  if (!flag("no-webapp")) {
    startWebapp(plan, convex);
    say(`webapp: starting on ${webappUrl(plan.ports)} (log ${logPath("webapp")})`);
  }
  writeEnvFile(plan, convex);
  say(`app up: ${join(RUN, "app.env")} lists the endpoints`);
}

/** Stopping order: the webapp first, the proxies last. */
const ORDER = ["webapp", "faucet", "keeper", "monitor", "convex", "content", "indexer", ...APP_CHAINS.map((c) => `proxy-${c.network}`)];

function status(): void {
  const all = [...ORDER.filter((n) => record(n)), ...names().filter((n) => !ORDER.includes(n))];
  if (all.length === 0) say("test-network app: nothing started");
  for (const n of all) say(`  ${n.padEnd(22)} ${running(n) ? "running" : "stopped"} pid ${record(n)?.pid} log ${record(n)?.log}`);
}

function down(): void {
  for (const n of ORDER) if (stop(n)) say(`stopped ${n}`);
}

async function main() {
  try {
    switch (argv[0]) {
      case "up":
        await up();
        break;
      case "status":
        status();
        break;
      case "down":
        down();
        break;
      default:
        say("usage: node script/testnet/app.ts up [--chains sepolia,base-sepolia] [--deployments <dir>] [--gas-eth <eth>] [--no-webapp] | status | down");
        process.exitCode = 2;
    }
  } catch (e) {
    say(e instanceof Stop ? `STOPPED ${e.message}` : `FAILED ${(e as Error).stack ?? e}`);
    process.exitCode = 1;
  }
}

await main();
