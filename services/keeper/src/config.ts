// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The bot runner's configuration (.env.example lists every name). The LiquidationBot's own settings are its
// LIQUIDATION_BOT_* names (liquidator/README.md); the runner adds the release manifest the bots' contracts come from,
// the indexer's bot stream, the monitoring service, the kill switch and the metrics port, under KEEPER_* names. Secrets
// are read from files, never from the environment: the signer is an encrypted Foundry keystore with its password file,
// the stream key and the monitor token are files too.

import { readFileSync } from "node:fs";
import { ABI_HASH } from "@avana/protocol/abis";
import { type ServiceManifest, intEnv, loadManifest, optionalEnv, requireEnv } from "@avana/services-common";
import { type Settings, loadSettings } from "@avana/liquidator/bot";
import type { Address } from "viem";

export interface RunnerConfig {
  readonly manifest: ServiceManifest;
  readonly settings: Settings;
  /** The bot stream; null runs on the bots' own RPC discovery only. */
  readonly indexer: { readonly url: string; readonly keyFile: string } | null;
  readonly monitor: { readonly url: string; readonly instance: string; readonly token: string } | null;
  readonly haltStatePath: string;
  readonly killSwitch: { readonly port: number; readonly cert: string; readonly key: string; readonly clientCa: string } | null;
  readonly metricsPort: number | null;
}

type Env = Readonly<Record<string, string | undefined>>;

/** All of `names` or none of them; a partial set is refused. */
function together(env: Env, names: readonly string[]): boolean {
  const set = names.filter((n) => optionalEnv(env as NodeJS.ProcessEnv, n) !== undefined);
  if (set.length !== 0 && set.length !== names.length) throw new Error(`set ${names.join(", ")} together (missing: ${names.filter((n) => !set.includes(n)).join(", ")})`);
  return set.length === names.length;
}

export function loadRunnerConfig(env: Env, load: (path: string) => ServiceManifest = (p) => loadManifest(p, ABI_HASH), readText: (path: string) => string = (p) => readFileSync(p, "utf8")): RunnerConfig {
  const e = env as NodeJS.ProcessEnv;
  const settings = loadSettings(env);
  const manifest = load(requireEnv(e, "AVANA_MANIFEST"));
  if (manifest.chainId !== settings.chainId) throw new Error(`AVANA_MANIFEST is chain ${manifest.chainId}, LIQUIDATION_BOT_CHAIN_ID is ${settings.chainId}`);
  if (manifest.avana.integrations.length === 0) throw new Error("the manifest lists no integration: nothing to liquidate");
  const indexer = together(env, ["KEEPER_INDEXER_URL", "KEEPER_INDEXER_KEY_FILE"]) ? { url: requireEnv(e, "KEEPER_INDEXER_URL"), keyFile: requireEnv(e, "KEEPER_INDEXER_KEY_FILE") } : null;
  const monitor = together(env, ["KEEPER_MONITOR_URL", "KEEPER_MONITOR_INSTANCE", "KEEPER_MONITOR_TOKEN_FILE"])
    ? { url: requireEnv(e, "KEEPER_MONITOR_URL"), instance: requireEnv(e, "KEEPER_MONITOR_INSTANCE"), token: readText(requireEnv(e, "KEEPER_MONITOR_TOKEN_FILE")).trim() }
    : null;
  const killSwitch = together(env, ["KEEPER_KILL_SWITCH_PORT", "KEEPER_KILL_SWITCH_TLS_CERT", "KEEPER_KILL_SWITCH_TLS_KEY", "KEEPER_KILL_SWITCH_CLIENT_CA"])
    ? { port: intEnv(e, "KEEPER_KILL_SWITCH_PORT"), cert: requireEnv(e, "KEEPER_KILL_SWITCH_TLS_CERT"), key: requireEnv(e, "KEEPER_KILL_SWITCH_TLS_KEY"), clientCa: requireEnv(e, "KEEPER_KILL_SWITCH_CLIENT_CA") }
    : null;
  return {
    manifest,
    settings,
    indexer,
    monitor,
    haltStatePath: requireEnv(e, "KEEPER_HALT_STATE_PATH"),
    killSwitch,
    metricsPort: optionalEnv(e, "KEEPER_METRICS_PORT") ? intEnv(e, "KEEPER_METRICS_PORT") : null,
  };
}

/** Each integration's contracts for its LiquidationBot; a FlashLiquidator only when `operator` is its OPERATOR. */
export function integrationsOf(m: ServiceManifest, operator: Address): { integrationId: number; aaveAdapter: Address; liquidationModule: Address; flashLiquidator?: Address }[] {
  return m.avana.integrations.map((x) => {
    const flash = m.avana.flashLiquidators.find((f) => f.integrationId === x.integrationId && f.operator.toLowerCase() === operator.toLowerCase());
    return { integrationId: x.integrationId, aaveAdapter: x.aaveAdapter.address, liquidationModule: x.liquidationModule.address, ...(flash ? { flashLiquidator: flash.address } : {}) };
  });
}

/** The debt reserves of each CDP Spoke (lower-case address), from the manifest. */
export function spokeDebtReservesOf(m: ServiceManifest): Map<string, bigint[]> {
  const out = new Map<string, bigint[]>();
  for (const r of m.debtReserves) out.set(r.spoke.toLowerCase(), [...(out.get(r.spoke.toLowerCase()) ?? []), r.debtReserveId]);
  return out;
}
