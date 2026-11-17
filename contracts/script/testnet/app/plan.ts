// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The test-network app's plan (script/testnet/app.ts): which chains run, where their deploy outputs are, which ports the
// services take, and the environment of every service. Pure functions of their inputs, so the tests check every
// service's environment from fixture manifests without a network.
//
// Every service reads a test network through a local RPC proxy (rpc-proxy.ts, http://127.0.0.1:<port>, its WebSocket
// on the same port): the RPC URL itself reaches only the proxy's environment, never a service's environment, a command
// line, a file or a log line.

import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, sep } from "node:path";

export interface AppChain {
  /** The deploy's network name: its outputs are in <deployments>/<network>/ (script/testnet/testnet.ts). */
  readonly network: "sepolia" | "base-sepolia";
  readonly chainId: number;
  readonly label: string;
  /** The app's chain (the webapp's and the faucet's key): Sepolia is the test networks' Ethereum, Base Sepolia their Base. */
  readonly appKey: "ethereum" | "base";
  /** The services' chain key (services/common/src/chains.ts, network set `testnet`). */
  readonly serviceKey: "sepolia" | "baseSepolia";
  /** RPC_<envSuffix>, the name every service reads. */
  readonly envSuffix: "SEPOLIA" | "BASE_SEPOLIA";
  /** The variable holding the network's RPC URL: the environment, or the encrypted secrets of `stack.ts secrets`. */
  readonly rpcSecret: "SEPOLIA_RPC_URL" | "BASE_SEPOLIA_RPC_URL";
  readonly blockTime: number;
  /** The public block explorer (the About card's links). */
  readonly explorerUrl: string;
}

export const APP_CHAINS: readonly AppChain[] = [
  {
    network: "sepolia",
    chainId: 11_155_111,
    label: "Sepolia",
    appKey: "ethereum",
    serviceKey: "sepolia",
    envSuffix: "SEPOLIA",
    rpcSecret: "SEPOLIA_RPC_URL",
    blockTime: 12,
    explorerUrl: "https://sepolia.etherscan.io",
  },
  {
    network: "base-sepolia",
    chainId: 84_532,
    label: "Base Sepolia",
    appKey: "base",
    serviceKey: "baseSepolia",
    envSuffix: "BASE_SEPOLIA",
    rpcSecret: "BASE_SEPOLIA_RPC_URL",
    blockTime: 2,
    explorerUrl: "https://sepolia.basescan.org",
  },
];

/** The network label the webapp's NetworkBadge shows (NEXT_PUBLIC_AVANA_NETWORK_LABEL). */
export const NETWORK_LABEL = "Sepolia";

/** `--chains` (comma-separated network names or chain IDs), both test networks when unset, in a fixed order. */
export function selectChains(list: string | undefined): AppChain[] {
  if (!list) return [...APP_CHAINS];
  const want = list.split(",").map((s) => s.trim()).filter(Boolean);
  if (want.length === 0) throw new Error("--chains names no chain");
  for (const w of want) {
    if (!APP_CHAINS.some((c) => c.network === w || String(c.chainId) === w)) throw new Error(`--chains: no test network ${w} (${APP_CHAINS.map((c) => c.network).join(", ")})`);
  }
  return APP_CHAINS.filter((c) => want.includes(c.network) || want.includes(String(c.chainId)));
}

export interface Ports {
  readonly indexer: number;
  readonly content: number;
  readonly keeperMetrics: number;
  readonly keeperKill: number;
  readonly monitor: number;
  readonly faucet: number;
  readonly webapp: number;
  readonly proxy: Readonly<Record<AppChain["network"], number>>;
}

/**
 * The app's ports, none the local stack's (8545, 8546, 42070, 42080, 3000, ...), so both can run on one machine.
 * APP_PORT_<NAME> moves one (INDEXER, CONTENT, KEEPER_METRICS, KEEPER_KILL, MONITOR, FAUCET, WEBAPP, PROXY_SEPOLIA,
 * PROXY_BASE_SEPOLIA). Two services on one port are refused.
 */
export function appPorts(env: Readonly<Record<string, string | undefined>>): Ports {
  const int = (name: string, d: number) => {
    const raw = env[`APP_PORT_${name}`]?.trim();
    if (!raw) return d;
    const n = Number(raw);
    if (!Number.isInteger(n) || n < 1024 || n > 65_535) throw new Error(`APP_PORT_${name} must be a port number from 1024 to 65535`);
    return n;
  };
  const ports: Ports = {
    indexer: int("INDEXER", 42_170),
    content: int("CONTENT", 8_888),
    keeperMetrics: int("KEEPER_METRICS", 9_564),
    keeperKill: int("KEEPER_KILL", 9_565),
    monitor: int("MONITOR", 9_570),
    faucet: int("FAUCET", 42_180),
    webapp: int("WEBAPP", 3_100),
    proxy: { sepolia: int("PROXY_SEPOLIA", 8_665), "base-sepolia": int("PROXY_BASE_SEPOLIA", 8_666) },
  };
  const all = [ports.indexer, ports.content, ports.keeperMetrics, ports.keeperKill, ports.monitor, ports.faucet, ports.webapp, ...Object.values(ports.proxy)];
  if (new Set(all).size !== all.length) throw new Error("two of the app's services are given one port");
  return ports;
}

/** The local proxy of a chain, as every service reaches it: http, a second spelling (the monitor and the keeper refuse a
 * fallback equal to the primary), and its WebSocket. */
export const proxyUrl = (p: Ports, c: AppChain) => `http://127.0.0.1:${p.proxy[c.network]}`;
export const proxyFallbackUrl = (p: Ports, c: AppChain) => `http://localhost:${p.proxy[c.network]}`;
export const proxyWsUrl = (p: Ports, c: AppChain) => `ws://127.0.0.1:${p.proxy[c.network]}`;
export const webappUrl = (p: Ports) => `http://127.0.0.1:${p.webapp}`;
export const indexerUrl = (p: Ports) => `http://127.0.0.1:${p.indexer}`;
export const faucetUrl = (p: Ports) => `http://127.0.0.1:${p.faucet}`;

/** Where the deploy wrote each network's outputs (testnet.ts: <deployments>/<network>/manifest.json, world.json). */
export const outDirOf = (deployments: string, c: AppChain) => join(deployments, c.network);
export const manifestOf = (deployments: string, c: AppChain) => join(outDirOf(deployments, c), "manifest.json");
/** testnet.ts's rehearsal mark: outputs of a run on local nodes with the networks' chain IDs, never served. */
export const REHEARSAL_MARK = ".rehearsal";

/** Every reason the deploy outputs of `chains` cannot be served: missing, a rehearsal's, or another chain's manifest. */
export function checkOutputs(deployments: string, chains: readonly AppChain[]): string[] {
  const errors: string[] = [];
  for (const c of chains) {
    const m = manifestOf(deployments, c);
    if (!existsSync(m)) {
      errors.push(`${c.network}: no manifest at ${m}: deploy it first (script/testnet/testnet.ts deploy --chain ${c.network})`);
      continue;
    }
    if (existsSync(join(outDirOf(deployments, c), REHEARSAL_MARK))) errors.push(`${c.network}: ${outDirOf(deployments, c)} holds a rehearsal's outputs, not the network's`);
    const j = JSON.parse(readFileSync(m, "utf8")) as { chainId?: number; network?: string };
    if (j.chainId !== c.chainId) errors.push(`${c.network}: the manifest is for chain ${j.chainId}, not ${c.chainId}`);
    if (!existsSync(join(outDirOf(deployments, c), "world.json"))) errors.push(`${c.network}: no world.json next to the manifest`);
  }
  return errors;
}

/** The private test-network config file (AVANA_TESTNET_CONFIG, KEY=VALUE lines, testnet.ts's): the faucet's signer is
 * its DEPLOYER keystore, the test tokens' minter. Only paths are read; the keystore is decrypted by the faucet. */
export interface FaucetSigner {
  readonly keystore: string;
  readonly passwordFile: string;
}

export function parseConfigFile(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const i = line.indexOf("=");
    if (i === -1) throw new Error("the test-network config file has a line that is not KEY=VALUE");
    out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
  return out;
}

export function faucetSignerOf(f: Readonly<Record<string, string | undefined>>): FaucetSigner {
  const errors: string[] = [];
  if (!f.KEYSTORE_DIR) errors.push("KEYSTORE_DIR");
  if (!f.PASSWORD_FILE) errors.push("PASSWORD_FILE");
  if (!f.DEPLOYER || /[\\/]/.test(f.DEPLOYER)) errors.push("DEPLOYER (a keystore name in KEYSTORE_DIR)");
  if (errors.length) throw new Error(`the test-network config file lacks ${errors.join(", ")}`);
  return { keystore: join(f.KEYSTORE_DIR!, f.DEPLOYER!), passwordFile: f.PASSWORD_FILE! };
}

/** Random values the app makes once and keeps in its run directory (bearer tokens and HMAC secrets, no signing key of
 * any chain), and the webapp's session-signing JWK. */
export interface AppSecrets {
  readonly exportSecret: string;
  readonly monitorStatusToken: string;
  readonly keeperTokens: Readonly<Record<string, string>>;
  readonly sessionSecret: string;
  readonly rateLimitSecret: string;
  readonly siweJwk: string;
}

export interface Plan {
  readonly chains: readonly AppChain[];
  readonly ports: Ports;
  /** The deploy outputs' root (<checkout>/contracts/deployments-local of the checkout that deployed). */
  readonly deployments: string;
  /** This app's own state: process logs and records, stores, secrets (<this checkout>/contracts/deployments-local/testnet-app). */
  readonly run: string;
  readonly secrets: AppSecrets;
}

export const EXPORT_KEY_ID = "testnet-app";
const manifests = (p: Plan) => p.chains.map((c) => manifestOf(p.deployments, c)).join(",");

/** The proxy of chain `c`: the network's RPC URL in its environment only. */
export const proxyEnv = (rpcUrl: string, origins: readonly string[]): Record<string, string> => ({ PROXY_UPSTREAMS: rpcUrl, PROXY_CORS_ORIGINS: origins.join(",") });

/** The indexer's code: what, with the manifests, makes Ponder's build (its config reads them). */
const INDEXER_CODE = ["package.json", "ponder.config.ts", "ponder.schema.ts", "src"];

function filesUnder(path: string): string[] {
  if (!existsSync(path)) return [];
  if (!statSync(path).isDirectory()) return [path];
  return readdirSync(path).sort().flatMap((n) => filesUnder(join(path, n)));
}

/**
 * The indexer's schema: `testnet_<12 hex>`, a hash of the manifest files and the indexer's code. Ponder resumes a schema
 * only under the same build, and the build includes the manifests, so a Hub release that rewrites a manifest (or a code
 * change) gets a new schema and a full reindex instead of Ponder refusing the old one.
 */
export function indexerSchema(indexerDir: string, manifestPaths: readonly string[]): string {
  const h = createHash("sha256");
  for (const f of manifestPaths) h.update(`manifest\0${readFileSync(f)}\0`);
  for (const f of INDEXER_CODE.flatMap((x) => filesUnder(join(indexerDir, x)))) h.update(`${relative(indexerDir, f).split(sep).join("/")}\0`).update(readFileSync(f)).update("\0");
  return `testnet_${h.digest("hex").slice(0, 12)}`;
}

/** The schema file of the app's run directory: the schema the running indexer was started on. */
export const indexerSchemaFile = (run: string) => join(run, "indexer-schema");

export const manifestPathsOf = (p: Pick<Plan, "chains" | "deployments">) => p.chains.map((c) => manifestOf(p.deployments, c));

export function indexerEnv(p: Plan, schema: string): Record<string, string> {
  const env: Record<string, string> = {
    AVANA_MANIFEST: manifests(p),
    INDEXER_NETWORK_SET: "testnet",
    INDEXER_DATABASE: "pglite",
    DATABASE_SCHEMA: schema,
    PONDER_TELEMETRY_DISABLED: "true",
    INDEXER_EXPORT_KEYS: `${EXPORT_KEY_ID}:${p.secrets.exportSecret}`,
  };
  for (const c of p.chains) {
    env[`RPC_${c.envSuffix}`] = proxyUrl(p.ports, c);
    env[`RPC_${c.envSuffix}_FALLBACK`] = proxyFallbackUrl(p.ports, c);
    env[`RPC_${c.envSuffix}_WS`] = proxyWsUrl(p.ports, c);
  }
  return env;
}

/** The Convex deployment's environment: the chains' RPCs (the proxies), the cron chain list, the indexer export, the
 * listing content and the session secrets. */
export function convexVars(p: Plan): Record<string, string> {
  const vars: Record<string, string> = {
    AVANA_CHAIN_IDS: p.chains.map((c) => c.chainId).join(","),
    SIWE_JWT_ISSUER: webappUrl(p.ports),
    INDEXER_EXPORT_URL: indexerUrl(p.ports),
    INDEXER_EXPORT_KEY_ID: EXPORT_KEY_ID,
    INDEXER_EXPORT_SECRET: p.secrets.exportSecret,
    LISTING_CONTENT_URL: `http://127.0.0.1:${p.ports.content}`,
    CONVEX_SESSION_SECRET: p.secrets.sessionSecret,
    CONVEX_RATE_LIMIT_SECRET: p.secrets.rateLimitSecret,
  };
  for (const c of p.chains) {
    vars[`RPC_${c.envSuffix}`] = proxyUrl(p.ports, c);
    vars[`RPC_${c.envSuffix}_FALLBACK`] = proxyFallbackUrl(p.ports, c);
  }
  return vars;
}

/**
 * The keeper on the test networks. A test-network keeper signs only through the KMS (Q-245: the keeper refuses a local
 * keystore off a development node), so it runs in observe mode unless KEEPER_KMS_KEY_ID_<SUFFIX> is set for a chain
 * (passed in `kms`); then it is active there, with the local figures for its gas ceiling and daily spend.
 */
export function keeperEnv(p: Plan, tls: { cert: string; key: string }, kms: Readonly<Record<string, string | undefined>>): Record<string, string> {
  const signing = p.chains.filter((c) => kms[`KEEPER_KMS_KEY_ID_${c.envSuffix}`]);
  const env: Record<string, string> = {
    AVANA_MANIFEST: manifests(p),
    KEEPER_NETWORK_SET: "testnet",
    KEEPER_MODE: signing.length > 0 ? "active" : "observe",
    KEEPER_ROLE: "primary",
    KEEPER_SHARD: "0",
    KEEPER_SHARD_COUNT: "1",
    KEEPER_KILL_SWITCH_PORT: String(p.ports.keeperKill),
    KEEPER_KILL_SWITCH_TLS_CERT: tls.cert,
    KEEPER_KILL_SWITCH_TLS_KEY: tls.key,
    KEEPER_KILL_SWITCH_CLIENT_CA: tls.cert,
    KEEPER_HALT_STATE_PATH: join(p.run, "keeper", "halt"),
    KEEPER_METRICS_PORT: String(p.ports.keeperMetrics),
    KEEPER_INDEXER_URL: indexerUrl(p.ports),
    KEEPER_INDEXER_KEY: `${EXPORT_KEY_ID}:${p.secrets.exportSecret}`,
    KEEPER_MONITOR_URL: `http://127.0.0.1:${p.ports.monitor}`,
  };
  for (const c of p.chains) {
    env[`RPC_${c.envSuffix}`] = proxyUrl(p.ports, c);
    env[`RPC_${c.envSuffix}_FALLBACK`] = proxyFallbackUrl(p.ports, c);
    env[`RPC_${c.envSuffix}_WS`] = proxyWsUrl(p.ports, c);
    env[`RPC_${c.envSuffix}_PRIVATE`] = proxyUrl(p.ports, c);
    env[`KEEPER_MONITOR_INSTANCE_${c.envSuffix}`] = `keeper-${c.serviceKey}`;
    env[`KEEPER_MONITOR_TOKEN_${c.envSuffix}`] = p.secrets.keeperTokens[c.serviceKey]!;
    if (signing.includes(c)) {
      env[`KEEPER_KMS_KEY_ID_${c.envSuffix}`] = kms[`KEEPER_KMS_KEY_ID_${c.envSuffix}`]!;
      env[`KEEPER_GAS_CEILING_WEI_${c.envSuffix}`] = "1000000000000000000";
      env[`KEEPER_GAS_DAILY_SPEND_WEI_${c.envSuffix}`] = "100000000000000000";
    }
  }
  return env;
}

const RECIPIENTS = ["onCall", "governanceSafeSigners", "emergencyGuardianSigners", "aaveProtocolGuardian", "operators", "emergencyGuardian", "guardians", "riskProviders", "governance", "standbyKeeper", "keeperOnCall", "avanaLabs", "aaveDao", "aave", "coverageRole", "engineering", "cancellers", "signers"];

/** The monitor on the test networks; every recipient is routed to its log. */
export function monitorEnv(p: Plan): Record<string, string> {
  const env: Record<string, string> = {
    AVANA_MANIFEST: manifests(p),
    MONITOR_NETWORK_SET: "testnet",
    MONITOR_CHANNELS: "log:log",
    MONITOR_KEEPER_INSTANCES: p.chains.map((c) => `keeper-${c.serviceKey}:${c.serviceKey}`).join(","),
    MONITOR_STATUS_TOKEN: p.secrets.monitorStatusToken,
    MONITOR_INCIDENT_LOG: join(p.run, "monitor", "incidents.jsonl"),
    MONITOR_STATE_PATH: join(p.run, "monitor", "state.json"),
    MONITOR_PORT: String(p.ports.monitor),
  };
  for (const r of RECIPIENTS) env[`MONITOR_ROUTE_${r.replace(/[A-Z]/g, (x) => `_${x}`).toUpperCase()}`] = "log";
  for (const c of p.chains) {
    env[`RPC_${c.envSuffix}`] = proxyUrl(p.ports, c);
    env[`RPC_${c.envSuffix}_FALLBACK`] = proxyFallbackUrl(p.ports, c);
    env[`MONITOR_KEEPER_TOKEN_KEEPER_${c.serviceKey.replace(/[^A-Za-z0-9]/g, "_").toUpperCase()}`] = p.secrets.keeperTokens[c.serviceKey]!;
  }
  return env;
}

/** The faucet in test-network mode: it mints the test tokens from the deployer keystore (the tokens' minter). */
export function faucetEnv(p: Plan, signer: FaucetSigner, gasEth: string): Record<string, string> {
  const env: Record<string, string> = {
    FAUCET_CHAIN_KIND: "testnet",
    FAUCET_CHAIN_IDS: p.chains.map((c) => c.chainId).join(","),
    FAUCET_PORT: String(p.ports.faucet),
    FAUCET_DATA_DIR: join(p.run, "faucet"),
    FAUCET_SIGNER_KEYSTORE: signer.keystore,
    FAUCET_SIGNER_PASSWORD_FILE: signer.passwordFile,
    FAUCET_GAS_ETH: gasEth,
  };
  for (const c of p.chains) {
    env[`FAUCET_RPC_${c.appKey.toUpperCase()}`] = proxyUrl(p.ports, c);
    env[`FAUCET_MANIFEST_${c.appKey.toUpperCase()}`] = manifestOf(p.deployments, c);
  }
  return env;
}

/** The webapp's environment: the test networks' chain IDs, the proxies as its read RPCs, the local Convex, the faucet,
 * the session issuer and key, and the "Sepolia" network badge. */
export function webappEnv(p: Plan, convex: { url: string; siteUrl: string | undefined }): Record<string, string> {
  const of = (k: AppChain["appKey"]) => APP_CHAINS.find((c) => c.appKey === k)!;
  const opens = p.chains[0]!;
  const env: Record<string, string> = {
    NEXT_PUBLIC_CONVEX_URL: convex.url,
    NEXT_PUBLIC_CONVEX_SITE_URL: convex.siteUrl ?? "",
    CONVEX_URL: convex.url,
    NEXT_PUBLIC_AVANA_ETHEREUM_CHAIN_ID: String(of("ethereum").chainId),
    NEXT_PUBLIC_AVANA_BASE_CHAIN_ID: String(of("base").chainId),
    NEXT_PUBLIC_AVANA_CHAIN_ID: String(opens.chainId),
    NEXT_PUBLIC_AVANA_NETWORK_LABEL: NETWORK_LABEL,
    NEXT_PUBLIC_AVANA_SWAP_PROVIDER: "onchain-pools",
    NEXT_PUBLIC_SIWE_ISSUER: webappUrl(p.ports),
    SIWE_JWT_PRIVATE_JWK: p.secrets.siweJwk,
    CONVEX_RATE_LIMIT_SECRET: p.secrets.rateLimitSecret,
    FAUCET_URL: faucetUrl(p.ports),
  };
  for (const c of p.chains) env[`NEXT_PUBLIC_RPC_${c.appKey.toUpperCase()}`] = proxyUrl(p.ports, c);
  return env;
}

/** `text` with every value of `secrets` replaced by its name: what any line the app prints passes through. */
export function redact(text: string, secrets: Readonly<Record<string, string | undefined>>): string {
  let out = text;
  for (const [name, value] of Object.entries(secrets)) {
    if (!value || value.length < 8) continue;
    out = out.split(value).join(`<${name}>`);
    // The URL's host and path alone (an error may name them without the scheme).
    try {
      const u = new URL(value);
      for (const part of [`${u.host}${u.pathname}`, u.pathname.length > 8 ? u.pathname : ""]) if (part) out = out.split(part).join(`<${name}>`);
    } catch {}
  }
  return out;
}
