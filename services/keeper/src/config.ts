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
import type { Address } from "viem";
import { type FeePolicy, GWEI, paysL1DataFee } from "./chain/gas.ts";
import { type StreamKey, parseStreamKey } from "./discovery/indexerStream.ts";
import type { LocalKeystore } from "./adapters/localKeystore.ts";
import { DISCOVERY_PAGE_SECONDS } from "./monitoring/discovery.ts";
import { parseLargest } from "./monitoring/funding.ts";

export type KeeperMode = "observe" | "active";
export type KeeperRole = "primary" | "standby";

export interface ChainConfig {
  readonly chain: ChainInfo;
  readonly manifest: ServiceManifest;
  readonly rpc: { readonly primary: string; readonly fallback: string; readonly ws: string; readonly privateSend: readonly string[] };
  /** Undefined runs this chain in observe-only mode whatever KEEPER_MODE says (unless a local rehearsal key is set). */
  readonly kmsKeyId: string | undefined;
  /** An encrypted keystore (KEEPER_LOCAL_KEYSTORE_ANVIL), accepted only on the `local` network set: the anvil drills. */
  readonly localKeystore: LocalKeystore | undefined;
  /** Worst-case wei one transaction may cost (KEEPER_GAS_CEILING_WEI_<CHAIN>); required wherever a signer is set. */
  readonly gasCeilingWei: bigint | undefined;
  /** Largest single debtToCover the chain's caps allow, per debt asset (lower-case), base units: M-16 and M-17. */
  readonly largestDebtToCover: ReadonlyMap<string, bigint>;
  /** The signer's expected daily gas spend, the floor of M-17's measured median; required wherever a signer is set. */
  readonly gasDailySpendWei: bigint | undefined;
  /** Tips and the lazy base-fee gate per job class (KEEPER_MIN_TIP_*, KEEPER_LAZY_*); defaults in `feePolicy`. */
  readonly feePolicy: FeePolicy;
  /**
   * Rolling 24 h budget in wei of the scheduled and lazy classes (KEEPER_DAILY_BUDGET_WEI_{SCHEDULED,LAZY}_<CHAIN>);
   * a class at its budget stops sending and pages M-32. Undefined without a daily spend (observe-only). Urgent has none.
   */
  readonly dailyBudgetWei: { readonly scheduled: bigint; readonly lazy: bigint } | undefined;
  /** The standby instance's signer on this chain and its minimum gas balance (M-33); null when not configured. */
  readonly standby: { readonly signer: Address; readonly minBalanceWei: bigint } | null;
  /**
   * A Chainlink feed of the chain's gas token in USD (KEEPER_NATIVE_USD_FEED_<CHAIN>), used only to value a
   * liquidation's reward in wei for the small-account spend metric; null leaves that metric unreported.
   */
  readonly nativeUsdFeed: Address | null;
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
  /** How long an account may stay one-sided between the discovery sources before M-30 pages, in seconds. */
  readonly discoveryPageSeconds: number;
}

/** KEEPER_DISCOVERY_MISMATCH_PAGE_SECONDS: a positive whole number of seconds, 3,600 when unset. */
export function discoveryPageSeconds(env: NodeJS.ProcessEnv): number {
  const name = "KEEPER_DISCOVERY_MISMATCH_PAGE_SECONDS";
  const raw = optionalEnv(env, name);
  if (raw === undefined) return DISCOVERY_PAGE_SECONDS;
  if (!/^\d+$/.test(raw) || Number(raw) === 0 || !Number.isSafeInteger(Number(raw))) throw new Error(`${name} must be a positive integer number of seconds`);
  return Number(raw);
}

/**
 * KEEPER_LOCAL_KEYSTORE_<CHAIN>: the path of an encrypted keystore (`cast wallet import`), with its password in the file
 * KEEPER_LOCAL_KEYSTORE_PASSWORD_FILE. Refused outside the `local` network set, so no published or test-network keeper
 * signs with a local key (Q-245); no raw key is ever read from the environment.
 */
export function localKeystore(env: NodeJS.ProcessEnv, chain: ChainInfo): LocalKeystore | undefined {
  const name = `KEEPER_LOCAL_KEYSTORE_${chain.envSuffix}`;
  const path = optionalEnv(env, name);
  if (path === undefined) return undefined;
  if (chain.networkSet !== "local") throw new Error(`${name} is accepted only on the local network set; sign through the KMS`);
  const passwordFile = optionalEnv(env, "KEEPER_LOCAL_KEYSTORE_PASSWORD_FILE");
  if (passwordFile === undefined) throw new Error(`${name} needs KEEPER_LOCAL_KEYSTORE_PASSWORD_FILE, the file holding its password`);
  return { path, passwordFile };
}

/** A decimal wei amount; a missing or zero ceiling stops startup on a chain that can sign. */
export function gasCeiling(env: NodeJS.ProcessEnv, name: string): bigint | undefined {
  const raw = optionalEnv(env, name);
  if (raw === undefined) return undefined;
  if (!/^\d+$/.test(raw) || BigInt(raw) === 0n) throw new Error(`${name} must be a positive integer number of wei`);
  return BigInt(raw);
}

/** A decimal wei amount with a default; zero and anything but digits are refused, as for `gasCeiling`. */
export function weiOr(env: NodeJS.ProcessEnv, name: string, fallback: bigint): bigint {
  return gasCeiling(env, name) ?? fallback;
}

/** A positive whole number of seconds with a default. */
export function secondsOr(env: NodeJS.ProcessEnv, name: string, fallback: bigint): bigint {
  const raw = optionalEnv(env, name);
  if (raw === undefined) return fallback;
  if (!/^\d+$/.test(raw) || BigInt(raw) === 0n) throw new Error(`${name} must be a positive integer number of seconds`);
  return BigInt(raw);
}

/**
 * Default fee policy of a chain. Urgent keeps today's rule (at least 1 gwei). The scheduled and lazy values are
 * conservative starting points, lower on an OP Stack chain (Base), whose base fee is a few thousandths of a gwei; they
 * are replaced by the inclusion-delay measurement of the AvanaGas design (section 6: a scheduled poke lands inside the
 * 60 s lead in at least 99 % of trials) through the KEEPER_MIN_TIP_* and KEEPER_LAZY_* variables.
 */
export function defaultFeePolicy(chain: Pick<ChainInfo, "key">): FeePolicy {
  const rollup = paysL1DataFee(chain);
  return {
    minTipUrgent: GWEI,
    minTipScheduled: rollup ? GWEI / 100n : GWEI / 2n,
    minTipLazy: rollup ? GWEI / 1_000n : GWEI / 10n,
    lazyBaseFeeMax: rollup ? GWEI / 20n : GWEI,
    lazyMaxWaitSeconds: 3_600n,
  };
}

/**
 * KEEPER_MIN_TIP_{URGENT,SCHEDULED,LAZY}_<CHAIN>, KEEPER_LAZY_BASEFEE_MAX_<CHAIN> (wei) and KEEPER_LAZY_MAX_WAIT_<CHAIN>
 * (seconds), each defaulting to `defaultFeePolicy`. The tips must not rise from urgent to lazy, so a non-urgent
 * transaction never outbids a liquidation.
 */
export function feePolicy(env: NodeJS.ProcessEnv, chain: Pick<ChainInfo, "key" | "envSuffix">): FeePolicy {
  const d = defaultFeePolicy(chain);
  const sfx = chain.envSuffix;
  const p: FeePolicy = {
    minTipUrgent: weiOr(env, `KEEPER_MIN_TIP_URGENT_${sfx}`, d.minTipUrgent),
    minTipScheduled: weiOr(env, `KEEPER_MIN_TIP_SCHEDULED_${sfx}`, d.minTipScheduled),
    minTipLazy: weiOr(env, `KEEPER_MIN_TIP_LAZY_${sfx}`, d.minTipLazy),
    lazyBaseFeeMax: weiOr(env, `KEEPER_LAZY_BASEFEE_MAX_${sfx}`, d.lazyBaseFeeMax),
    lazyMaxWaitSeconds: secondsOr(env, `KEEPER_LAZY_MAX_WAIT_${sfx}`, d.lazyMaxWaitSeconds),
  };
  if (p.minTipScheduled > p.minTipUrgent) throw new Error(`KEEPER_MIN_TIP_SCHEDULED_${sfx} must not exceed KEEPER_MIN_TIP_URGENT_${sfx}`);
  if (p.minTipLazy > p.minTipScheduled) throw new Error(`KEEPER_MIN_TIP_LAZY_${sfx} must not exceed KEEPER_MIN_TIP_SCHEDULED_${sfx}`);
  return p;
}

/** Multiples of the expected daily spend that the class budgets default to: a volatile day doubles feed rounds. */
export const DEFAULT_BUDGET_DAYS = { scheduled: 3n, lazy: 1n } as const;

/** KEEPER_DAILY_BUDGET_WEI_{SCHEDULED,LAZY}_<CHAIN>; default 3 and 1 times KEEPER_GAS_DAILY_SPEND_WEI_<CHAIN>. */
export function dailyBudgets(env: NodeJS.ProcessEnv, sfx: string, dailySpend: bigint | undefined): ChainConfig["dailyBudgetWei"] {
  const scheduled = gasCeiling(env, `KEEPER_DAILY_BUDGET_WEI_SCHEDULED_${sfx}`);
  const lazy = gasCeiling(env, `KEEPER_DAILY_BUDGET_WEI_LAZY_${sfx}`);
  if (dailySpend === undefined && scheduled === undefined && lazy === undefined) return undefined;
  const base = dailySpend ?? 0n;
  const s = scheduled ?? base * DEFAULT_BUDGET_DAYS.scheduled;
  const l = lazy ?? base * DEFAULT_BUDGET_DAYS.lazy;
  if (s === 0n || l === 0n) throw new Error(`KEEPER_DAILY_BUDGET_WEI_SCHEDULED_${sfx} and KEEPER_DAILY_BUDGET_WEI_LAZY_${sfx} need KEEPER_GAS_DAILY_SPEND_WEI_${sfx} or both set`);
  return { scheduled: s, lazy: l };
}

const ADDRESS = /^0x[0-9a-fA-F]{40}$/;

/**
 * KEEPER_STANDBY_SIGNER_<CHAIN> and KEEPER_STANDBY_MIN_BALANCE_WEI_<CHAIN> (M-33). The minimum defaults to 3 days of
 * KEEPER_GAS_DAILY_SPEND_WEI_<CHAIN>, the level at which M-17 warns.
 */
export function standbySigner(env: NodeJS.ProcessEnv, sfx: string, dailySpend: bigint | undefined): ChainConfig["standby"] {
  const name = `KEEPER_STANDBY_SIGNER_${sfx}`;
  const signer = optionalEnv(env, name);
  const min = gasCeiling(env, `KEEPER_STANDBY_MIN_BALANCE_WEI_${sfx}`);
  if (signer === undefined) {
    if (min !== undefined) throw new Error(`KEEPER_STANDBY_MIN_BALANCE_WEI_${sfx} is set without ${name}`);
    return null;
  }
  if (!ADDRESS.test(signer)) throw new Error(`${name} must be an address`);
  const minBalanceWei = min ?? (dailySpend !== undefined ? dailySpend * 3n : undefined);
  if (minBalanceWei === undefined) throw new Error(`${name} needs KEEPER_STANDBY_MIN_BALANCE_WEI_${sfx} or KEEPER_GAS_DAILY_SPEND_WEI_${sfx}`);
  return { signer: signer as Address, minBalanceWei };
}

/** KEEPER_NATIVE_USD_FEED_<CHAIN>: an address, or null when unset. */
export function nativeUsdFeed(env: NodeJS.ProcessEnv, sfx: string): Address | null {
  const name = `KEEPER_NATIVE_USD_FEED_${sfx}`;
  const raw = optionalEnv(env, name);
  if (raw === undefined) return null;
  if (!ADDRESS.test(raw)) throw new Error(`${name} must be an address`);
  return raw as Address;
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
    localKeystore: localKeystore(env, chain),
    gasCeilingWei: gasCeiling(env, `KEEPER_GAS_CEILING_WEI_${chain.envSuffix}`),
    largestDebtToCover: parseLargest(listEnv(env, `KEEPER_LARGEST_DEBT_TO_COVER_${chain.envSuffix}`), `KEEPER_LARGEST_DEBT_TO_COVER_${chain.envSuffix}`),
    gasDailySpendWei: gasCeiling(env, `KEEPER_GAS_DAILY_SPEND_WEI_${chain.envSuffix}`),
    feePolicy: feePolicy(env, chain),
    dailyBudgetWei: dailyBudgets(env, chain.envSuffix, gasCeiling(env, `KEEPER_GAS_DAILY_SPEND_WEI_${chain.envSuffix}`)),
    standby: standbySigner(env, chain.envSuffix, gasCeiling(env, `KEEPER_GAS_DAILY_SPEND_WEI_${chain.envSuffix}`)),
    nativeUsdFeed: nativeUsdFeed(env, chain.envSuffix),
    monitor: monitorUrl
      ? { url: monitorUrl, instance: requireEnv(env, `KEEPER_MONITOR_INSTANCE_${chain.envSuffix}`), token: requireEnv(env, `KEEPER_MONITOR_TOKEN_${chain.envSuffix}`) }
      : null,
  }));
  if (chains.length === 0) throw new Error(`no verified manifest for any ${set} chain`);
  for (const c of chains) {
    const signs = Boolean(c.kmsKeyId || c.localKeystore);
    if (c.kmsKeyId && c.localKeystore) throw new Error(`set KEEPER_KMS_KEY_ID_${c.chain.envSuffix} or KEEPER_LOCAL_KEYSTORE_${c.chain.envSuffix}, not both`);
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
    discoveryPageSeconds: discoveryPageSeconds(env),
  };
}
