// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Keeper configuration from the environment (.env.example). Every address comes from a verified manifest;
// none is read from code, the indexer or another service. A missing value stops startup.

import {
  type ChainInfo,
  type NetworkSet,
  type ServiceManifest,
  chainsOf,
  intEnv,
  listEnv,
  loadManifest,
  optionalEnv,
  requireEnv,
  rpcEnvName,
} from "@avana/services-common";
import { ABI_HASH } from "@avana/protocol/abis";
import { type StreamKey, parseStreamKey } from "./discovery/indexerStream.ts";
import { parseLargest } from "./monitoring/funding.ts";

export type KeeperMode = "observe" | "active";
export type KeeperRole = "primary" | "standby";

export interface ChainConfig {
  readonly chain: ChainInfo;
  readonly manifest: ServiceManifest;
  readonly rpc: { readonly primary: string; readonly fallback: string; readonly ws: string; readonly privateSend: readonly string[] };
  /** Undefined runs this chain in observe-only mode whatever KEEPER_MODE says (unless a local rehearsal key is set). */
  readonly kmsKeyId: string | undefined;
  /** A raw test key (KEEPER_LOCAL_KEY_ANVIL), accepted only on the `local` network set: the anvil rehearsal's drills. */
  readonly localKey: `0x${string}` | undefined;
  /** Worst-case wei one transaction may cost (KEEPER_GAS_CEILING_WEI_<CHAIN>); required wherever a signer is set. */
  readonly gasCeilingWei: bigint | undefined;
  /** Largest single debtToCover the chain's caps allow, per debt asset (lower-case), base units: M-16 and M-17. */
  readonly largestDebtToCover: ReadonlyMap<string, bigint>;
  /** The signer's expected daily gas spend, the floor of M-17's measured median; required wherever a signer is set. */
  readonly gasDailySpendWei: bigint | undefined;
  /** This chain's instance at the monitoring service; null when KEEPER_MONITOR_URL is unset (log lines only). */
  readonly monitor: { readonly url: string; readonly instance: string; readonly token: string } | null;
}

export interface KeeperConfig {
  readonly mode: KeeperMode;
  readonly role: KeeperRole;
  /** Null on the standby, which acts on every account still liquidatable after 60 s. */
  readonly shard: { readonly index: number; readonly count: number } | null;
  readonly chains: readonly ChainConfig[];
  readonly killSwitch: { readonly port: number; readonly cert: string; readonly key: string; readonly clientCa: string; readonly statePath: string };
  readonly metricsPort: number;
  readonly indexerUrl: string;
  /** The keeper's key for the indexer stream, one of the indexer's INDEXER_EXPORT_KEYS (id:base64secret). */
  readonly indexerKey: StreamKey;
}

/**
 * KEEPER_LOCAL_KEY_<CHAIN>: a 32-byte hex key, refused outside the `local` network set, so no published or test-network
 * keeper can sign with a raw key (Q-245).
 */
export function localKey(env: NodeJS.ProcessEnv, chain: ChainInfo): `0x${string}` | undefined {
  const name = `KEEPER_LOCAL_KEY_${chain.envSuffix}`;
  const raw = optionalEnv(env, name);
  if (raw === undefined) return undefined;
  if (chain.networkSet !== "local") throw new Error(`${name} is accepted only on the local network set; sign through the KMS`);
  if (!/^0x[0-9a-fA-F]{64}$/.test(raw)) throw new Error(`${name} must be a 32-byte hex key`);
  return raw as `0x${string}`;
}

/** A decimal wei amount; a missing or zero ceiling stops startup on a chain that can sign. */
export function gasCeiling(env: NodeJS.ProcessEnv, name: string): bigint | undefined {
  const raw = optionalEnv(env, name);
  if (raw === undefined) return undefined;
  if (!/^\d+$/.test(raw) || BigInt(raw) === 0n) throw new Error(`${name} must be a positive integer number of wei`);
  return BigInt(raw);
}

export function loadConfig(env: NodeJS.ProcessEnv): KeeperConfig {
  const set = (optionalEnv(env, "KEEPER_NETWORK_SET") ?? "testnet") as NetworkSet;
  const mode = (optionalEnv(env, "KEEPER_MODE") ?? "observe") as KeeperMode;
  const role = (optionalEnv(env, "KEEPER_ROLE") ?? "primary") as KeeperRole;
  if (mode !== "observe" && mode !== "active") throw new Error("KEEPER_MODE must be observe or active");
  if (role !== "primary" && role !== "standby") throw new Error("KEEPER_ROLE must be primary or standby");

  const manifests = new Map(listEnv(env, "AVANA_MANIFEST").map((p) => {
    const m = loadManifest(p, ABI_HASH);
    return [m.chainId, m] as const;
  }));
  const monitorUrl = optionalEnv(env, "KEEPER_MONITOR_URL");
  if (monitorUrl !== undefined && !/^https?:\/\//.test(monitorUrl)) throw new Error("KEEPER_MONITOR_URL must be an http(s) URL");
  const chains = chainsOf(set).filter((c) => manifests.has(c.id)).map((chain): ChainConfig => ({
    chain,
    manifest: manifests.get(chain.id)!,
    rpc: {
      primary: requireEnv(env, rpcEnvName(chain, "PRIMARY")),
      fallback: requireEnv(env, rpcEnvName(chain, "FALLBACK")),
      ws: requireEnv(env, rpcEnvName(chain, "WS")),
      privateSend: listEnv(env, rpcEnvName(chain, "PRIVATE")),
    },
    kmsKeyId: optionalEnv(env, `KEEPER_KMS_KEY_ID_${chain.envSuffix}`),
    localKey: localKey(env, chain),
    gasCeilingWei: gasCeiling(env, `KEEPER_GAS_CEILING_WEI_${chain.envSuffix}`),
    largestDebtToCover: parseLargest(listEnv(env, `KEEPER_LARGEST_DEBT_TO_COVER_${chain.envSuffix}`), `KEEPER_LARGEST_DEBT_TO_COVER_${chain.envSuffix}`),
    gasDailySpendWei: gasCeiling(env, `KEEPER_GAS_DAILY_SPEND_WEI_${chain.envSuffix}`),
    monitor: monitorUrl
      ? { url: monitorUrl, instance: requireEnv(env, `KEEPER_MONITOR_INSTANCE_${chain.envSuffix}`), token: requireEnv(env, `KEEPER_MONITOR_TOKEN_${chain.envSuffix}`) }
      : null,
  }));
  if (chains.length === 0) throw new Error(`no verified manifest for any ${set} chain`);
  for (const c of chains) {
    const signs = Boolean(c.kmsKeyId || c.localKey);
    if (c.kmsKeyId && c.localKey) throw new Error(`set KEEPER_KMS_KEY_ID_${c.chain.envSuffix} or KEEPER_LOCAL_KEY_${c.chain.envSuffix}, not both`);
    // No public-mempool fallback exists: a chain without a private endpoint cannot leave observe-only mode.
    if (mode === "active" && signs && c.rpc.privateSend.length === 0) {
      throw new Error(`${rpcEnvName(c.chain, "PRIVATE")} is empty; active mode sends only through private order flow`);
    }
    // A signer without a fee ceiling could drain its gas wallet on a fault: refused at startup.
    if (signs && c.gasCeilingWei === undefined) throw new Error(`KEEPER_GAS_CEILING_WEI_${c.chain.envSuffix} is required with a signer`);
    // M-17's gas level needs a spend to compare with before 7 days are measured.
    if (signs && c.gasDailySpendWei === undefined) throw new Error(`KEEPER_GAS_DAILY_SPEND_WEI_${c.chain.envSuffix} is required with a signer`);
  }

  const shard = role === "standby" ? null : { index: intEnv(env, "KEEPER_SHARD"), count: intEnv(env, "KEEPER_SHARD_COUNT") };
  if (shard && (shard.count < 1 || shard.index >= shard.count)) throw new Error("KEEPER_SHARD must be below KEEPER_SHARD_COUNT");

  const killSwitchPort = intEnv(env, "KEEPER_KILL_SWITCH_PORT");
  const metricsPort = intEnv(env, "KEEPER_METRICS_PORT");
  if (killSwitchPort === metricsPort) throw new Error("the kill switch and metrics ports must differ");

  return {
    mode,
    role,
    shard,
    chains,
    killSwitch: {
      port: killSwitchPort,
      cert: requireEnv(env, "KEEPER_KILL_SWITCH_TLS_CERT"),
      key: requireEnv(env, "KEEPER_KILL_SWITCH_TLS_KEY"),
      clientCa: requireEnv(env, "KEEPER_KILL_SWITCH_CLIENT_CA"),
      statePath: requireEnv(env, "KEEPER_HALT_STATE_PATH"),
    },
    metricsPort,
    indexerUrl: requireEnv(env, "KEEPER_INDEXER_URL"),
    indexerKey: parseStreamKey(requireEnv(env, "KEEPER_INDEXER_KEY")),
  };
}
