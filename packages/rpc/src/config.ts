// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The manager's configuration: Aave's transport values, the health policy, and what the environment sets.
//
// Environment (all optional; a provider is used only when all its credentials are set):
//   ALCHEMY_API_KEY                                 primary provider
//   QUICKNODE_ENDPOINT_NAME, QUICKNODE_TOKEN        backup provider
//   AVANA_RPC_PROVIDERS        provider order for every chain, default `alchemy,quicknode`
//   AVANA_RPC_PROVIDERS_<SYM>  provider order for one chain (SYM: MAINNET, SEPOLIA, BASE, BASE_SEPOLIA)
//   RPC_<SYM>, RPC_WS_<SYM>    an explicit endpoint for one chain: when set it is the chain's only endpoint (the Aave
//                              toolbox's RPC_<CHAIN> override, kept as the escape hatch)

import { RPC_CHAINS } from "./chains.ts";
import { type Credentials, DEFAULT_PROVIDER_ORDER, PROVIDERS } from "./providers.ts";

/** The HTTP transport and client values of aave-address-book scripts/clients.ts. */
export interface TransportSettings {
  /** Per request, ms. */
  readonly timeout: number;
  /** JSON-RPC batching over HTTP. */
  readonly batch: boolean;
  /** Retries after the first attempt, across providers (Aave: per URL; here a retry may run on the backup). */
  readonly retryCount: number;
  /** Base of the exponential backoff, ms: retry n waits retryDelay * 2^n (viem's formula), or Retry-After. */
  readonly retryDelay: number;
  /** eth_call aggregation through Multicall3. */
  readonly multicall: boolean;
  /** WebSocket reconnection after a dropped socket (viem's defaults: 5 attempts, 2 s). */
  readonly wsReconnect: { readonly attempts: number; readonly delay: number };
  /** WebSocket keep-alive ping interval, ms. */
  readonly wsKeepAlive: number;
}

export const AAVE_TRANSPORT_DEFAULTS: TransportSettings = {
  timeout: 30_000,
  batch: true,
  retryCount: 5,
  retryDelay: 500,
  multicall: true,
  wsReconnect: { attempts: 5, delay: 2_000 },
  wsKeepAlive: 30_000,
};

/** When a provider is left and when it is taken back. */
export interface HealthPolicy {
  /** Consecutive infrastructure failures that take a provider out of use. */
  readonly failoverAfter: number;
  /** Consecutive good probes that bring it back (hysteresis: one good answer is not enough). */
  readonly recoverAfter: number;
  /** Time out of use before the first recovery probe, ms. */
  readonly recoverCooldownMs: number;
  /** Time between probes, ms (recovery probes, and the background freshness probe of the providers in use). */
  readonly probeIntervalMs: number;
  /** A probe's time limit, ms. */
  readonly probeTimeoutMs: number;
  /** A probe slower than this is not good, ms. */
  readonly maxLatencyMs: number;
  /** Probe the providers in use in the background every probeIntervalMs while requests flow. */
  readonly backgroundProbes: boolean;
}

export const DEFAULT_HEALTH_POLICY: HealthPolicy = {
  failoverAfter: 1,
  recoverAfter: 3,
  recoverCooldownMs: 30_000,
  probeIntervalMs: 10_000,
  probeTimeoutMs: 5_000,
  maxLatencyMs: 5_000,
  backgroundProbes: true,
};

/** One chain's settings. */
export interface ChainSettings {
  /** Provider order (ids of PROVIDERS), first is primary. */
  readonly providers?: readonly string[];
  /** An explicit HTTP endpoint: the chain's only HTTP endpoint when set. */
  readonly http?: string;
  /** An explicit WebSocket endpoint: the chain's only WebSocket endpoint when set. */
  readonly ws?: string;
  readonly maxLagBlocks?: number;
  readonly maxHeadAgeMs?: number;
}

export interface RpcEnvConfig {
  readonly credentials: Credentials;
  readonly providers: readonly string[];
  readonly chains: Readonly<Record<number, ChainSettings>>;
}

const list = (v: string | undefined) => v?.split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);

function checkProviders(ids: readonly string[], where: string): readonly string[] {
  for (const id of ids) if (!PROVIDERS[id]) throw new Error(`${where} names an unknown RPC provider ${id}: ${Object.keys(PROVIDERS).join(", ")}`);
  return ids;
}

/** The configuration the environment `env` sets (process.env by default). */
export function configFromEnv(env: Readonly<Record<string, string | undefined>> = process.env): RpcEnvConfig {
  const credentials: Record<string, string | undefined> = {};
  for (const p of Object.values(PROVIDERS)) for (const n of p.credentialNames) credentials[n] = env[n]?.trim() || undefined;
  const providers = checkProviders(list(env.AVANA_RPC_PROVIDERS) ?? DEFAULT_PROVIDER_ORDER, "AVANA_RPC_PROVIDERS");
  const chains: Record<number, ChainSettings> = {};
  for (const c of Object.values(RPC_CHAINS)) {
    const order = list(env[`AVANA_RPC_PROVIDERS_${c.symbol}`]);
    const http = env[`RPC_${c.symbol}`]?.trim() || undefined;
    const ws = env[`RPC_WS_${c.symbol}`]?.trim() || undefined;
    const s: { -readonly [K in keyof ChainSettings]: ChainSettings[K] } = {};
    if (order) s.providers = checkProviders(order, `AVANA_RPC_PROVIDERS_${c.symbol}`);
    if (http) s.http = http;
    if (ws) s.ws = ws;
    if (Object.keys(s).length) chains[c.id] = s;
  }
  return { credentials, providers, chains };
}
