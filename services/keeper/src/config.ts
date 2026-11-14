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

export type KeeperMode = "observe" | "active";
export type KeeperRole = "primary" | "standby";

export interface ChainConfig {
  readonly chain: ChainInfo;
  readonly manifest: ServiceManifest;
  readonly rpc: { readonly primary: string; readonly fallback: string; readonly ws: string; readonly privateSend: readonly string[] };
  /** Undefined runs this chain in observe-only mode whatever KEEPER_MODE says. */
  readonly kmsKeyId: string | undefined;
  /** Worst-case wei one transaction may cost (KEEPER_GAS_CEILING_WEI_<CHAIN>); required wherever a signer is set. */
  readonly gasCeilingWei: bigint | undefined;
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
    gasCeilingWei: gasCeiling(env, `KEEPER_GAS_CEILING_WEI_${chain.envSuffix}`),
  }));
  if (chains.length === 0) throw new Error(`no verified manifest for any ${set} chain`);
  for (const c of chains) {
    // No public-mempool fallback exists: a chain without a private endpoint cannot leave observe-only mode.
    if (mode === "active" && c.kmsKeyId && c.rpc.privateSend.length === 0) {
      throw new Error(`${rpcEnvName(c.chain, "PRIVATE")} is empty; active mode sends only through private order flow`);
    }
    // A signer without a fee ceiling could drain its gas wallet on a fault: refused at startup.
    if (c.kmsKeyId && c.gasCeilingWei === undefined) throw new Error(`KEEPER_GAS_CEILING_WEI_${c.chain.envSuffix} is required with a signer`);
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
