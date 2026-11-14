// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Configuration from the environment (.env.example lists every name). Anything missing stops the process at startup:
// a monitor that cannot reach a responder or a second provider would fail silently when it matters.

import { ABI_HASH } from "@avana/protocol/abis";
import { type ChainInfo, type NetworkSet, type ServiceManifest, aaveTopology, chainsOf, intEnv, listEnv, loadManifest, optionalEnv, requireEnv, rpcEnvName } from "@avana/services-common";
import type { ChainDeployment } from "@avana/services-common/views";
import type { KeeperInstance } from "./keeper.ts";
import { RECIPIENTS, type Recipient, type RoutingTable, checkRouting } from "./routing.ts";

export type ChannelConfig =
  | { readonly name: string; readonly kind: "pagerduty"; readonly routingKey: string }
  | { readonly name: string; readonly kind: "webhook"; readonly url: string }
  | { readonly name: string; readonly kind: "log" };

export interface ChainConfig {
  readonly chain: ChainInfo;
  readonly deployment: ChainDeployment;
  readonly rpc: { readonly primary: string; readonly second: string };
}

export interface MonitorConfig {
  readonly chains: readonly ChainConfig[];
  /** Seconds between snapshot reads of a chain. */
  readonly intervalSeconds: number;
  readonly channels: readonly ChannelConfig[];
  readonly routing: RoutingTable;
  readonly incidentLogPath: string;
  readonly port: number;
  readonly statusToken: string;
  readonly keeperInstances: readonly KeeperInstance[];
  readonly keeperTokens: ReadonlyMap<string, string>;
}

/** `MONITOR_ROUTE_ON_CALL` for `onCall`, `MONITOR_ROUTE_RISK_PROVIDERS` for `riskProviders`. */
export const routeEnvName = (r: Recipient) => `MONITOR_ROUTE_${r.replace(/[A-Z]/g, (c) => `_${c}`).toUpperCase()}`;
const envSuffix = (name: string) => name.replace(/[^A-Za-z0-9]/g, "_").toUpperCase();

/** The addresses the snapshot reader starts from, from the verified manifest (as the indexer's sampler does). */
export function deploymentOf(m: ServiceManifest): ChainDeployment {
  const t = aaveTopology(m);
  return {
    chainId: m.chainId,
    lens: m.avana.lens.address,
    marketRegistry: m.avana.marketRegistry.address,
    hubs: t.hubs.map((h) => ({ address: h.address, label: h.label })),
    lendSpokes: t.lendSpokes.map((s) => s.address),
    cdpSpokes: t.borrowSpokes.map((s) => s.address),
    firstLossReserves: m.avana.firstLossReserves.map((c) => ({ address: c.address, asset: c.asset, hub: c.hub })),
  };
}

export function loadConfig(env: NodeJS.ProcessEnv, load: (path: string) => ServiceManifest = (p) => loadManifest(p, ABI_HASH)): MonitorConfig {
  const set = (optionalEnv(env, "MONITOR_NETWORK_SET") ?? "testnet") as NetworkSet;
  if (!["production", "testnet", "local"].includes(set)) throw new Error("MONITOR_NETWORK_SET must be production, testnet or local");

  const manifests = new Map(listEnv(env, "AVANA_MANIFEST").map((p) => {
    const m = load(p);
    return [m.chainId, m] as const;
  }));
  const chains = chainsOf(set).filter((c) => manifests.has(c.id)).map((chain): ChainConfig => {
    const primary = requireEnv(env, rpcEnvName(chain, "PRIMARY"));
    const second = requireEnv(env, rpcEnvName(chain, "FALLBACK"));
    if (primary === second) throw new Error(`${rpcEnvName(chain, "FALLBACK")} must be a second provider, not the primary endpoint again`);
    return { chain, deployment: deploymentOf(manifests.get(chain.id)!), rpc: { primary, second } };
  });
  if (chains.length === 0) throw new Error(`AVANA_MANIFEST names no chain of the ${set} set`);

  const channels = listEnv(env, "MONITOR_CHANNELS").map((spec): ChannelConfig => {
    const [name, kind] = spec.split(":");
    if (!name || !kind) throw new Error(`MONITOR_CHANNELS entry ${spec} is not name:kind`);
    const v = (suffix: string) => requireEnv(env, `MONITOR_CHANNEL_${envSuffix(name)}_${suffix}`);
    if (kind === "pagerduty") return { name, kind, routingKey: v("ROUTING_KEY") };
    if (kind === "webhook") {
      const url = v("URL");
      if (!url.startsWith("https://")) throw new Error(`channel ${name}: webhook URL must be https`);
      return { name, kind, url };
    }
    if (kind === "log") return { name, kind };
    throw new Error(`channel ${name}: kind ${kind} is not pagerduty, webhook or log`);
  });
  const names = new Set(channels.map((c) => c.name));
  if (names.size !== channels.length) throw new Error("MONITOR_CHANNELS names a channel twice");
  const routing = checkRouting(Object.fromEntries(RECIPIENTS.map((r) => [r, listEnv(env, routeEnvName(r))])), names);

  const keeperInstances = listEnv(env, "MONITOR_KEEPER_INSTANCES").map((spec): KeeperInstance => {
    const [name, chainKey] = spec.split(":");
    const chain = chains.find((c) => c.chain.key === chainKey);
    if (!name || !chain) throw new Error(`MONITOR_KEEPER_INSTANCES entry ${spec} is not name:chain for a configured chain`);
    return { name, chainId: chain.chain.id };
  });
  const keeperTokens = new Map(keeperInstances.map((i) => [i.name, requireEnv(env, `MONITOR_KEEPER_TOKEN_${envSuffix(i.name)}`)]));

  return {
    chains,
    intervalSeconds: optionalEnv(env, "MONITOR_INTERVAL_SECONDS") ? intEnv(env, "MONITOR_INTERVAL_SECONDS") : 12,
    channels,
    routing,
    incidentLogPath: requireEnv(env, "MONITOR_INCIDENT_LOG"),
    port: optionalEnv(env, "MONITOR_PORT") ? intEnv(env, "MONITOR_PORT") : 9470,
    statusToken: requireEnv(env, "MONITOR_STATUS_TOKEN"),
    keeperInstances,
    keeperTokens,
  };
}
