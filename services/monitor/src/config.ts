// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Configuration from the environment (.env.example lists every name). Anything missing stops the process at startup:
// a monitor that cannot reach a responder or a second provider would fail silently when it matters.

import { ABI_HASH } from "@avana/protocol/abis";
import { type ChainInfo, type NetworkSet, type ServiceManifest, aaveTopology, chainsOf, intEnv, listEnv, loadManifest, optionalEnv, requireEnv, rpcEnvName } from "@avana/services-common";
import type { ChainDeployment } from "@avana/services-common/views";
import type { Address } from "viem";
import type { KeeperInstance } from "./keeper.ts";
import type { LivenessConfig } from "./liveness.ts";
import type { CoreHubGho, FrontendConfig, SafeConfig } from "./probes/external.ts";
import { RECIPIENTS, type Recipient, type RoutingTable, checkRouting } from "./routing.ts";

export type ChannelConfig =
  | { readonly name: string; readonly kind: "pagerduty"; readonly routingKey: string }
  | { readonly name: string; readonly kind: "webhook"; readonly url: string }
  | { readonly name: string; readonly kind: "log" };

export interface ChainConfig {
  readonly chain: ChainInfo;
  readonly manifest: ServiceManifest;
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
  /** The state file (state.ts) that carries open alerts and probe state across restarts. */
  readonly statePath: string;
  readonly port: number;
  readonly statusToken: string;
  readonly keeperInstances: readonly KeeperInstance[];
  readonly keeperTokens: ReadonlyMap<string, string>;
  /** The governance Safes watched on each chain (M-23). */
  readonly safes: ReadonlyMap<number, readonly SafeConfig[]>;
  /** The Core Hub's GHO asset each chain's Avana Hubs are compared with (M-29). */
  readonly coreHubGho: ReadonlyMap<number, CoreHubGho>;
  /** Seconds between route depth and GSM headroom measurements (M-11, M-12). */
  readonly routeCheckSeconds: number;
  /** Safe signer liveness periods (M-23). */
  readonly liveness: LivenessConfig;
  /** The frontend checked on one chain's round (M-27); null when not configured. */
  readonly frontend: (FrontendConfig & { readonly chainId: number }) | null;
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
    const manifest = manifests.get(chain.id)!;
    return { chain, manifest, deployment: deploymentOf(manifest), rpc: { primary, second } };
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

  const chainOf = (key: string | undefined, name: string, spec: string) => {
    const c = chains.find((x) => x.chain.key === key);
    if (!c) throw new Error(`${name} entry ${spec} names no configured chain`);
    return c.chain.id;
  };
  const address = (a: string | undefined, name: string, spec: string) => {
    if (!a || !/^0x[0-9a-fA-F]{40}$/.test(a)) throw new Error(`${name} entry ${spec} has no valid address`);
    return a.toLowerCase() as Address;
  };
  const safes = new Map<number, SafeConfig[]>();
  for (const spec of listEnv(env, "MONITOR_SAFES")) {
    const [label, key, a] = spec.split(":");
    const id = chainOf(key, "MONITOR_SAFES", spec);
    safes.set(id, [...(safes.get(id) ?? []), { label: label || a!, address: address(a, "MONITOR_SAFES", spec) }]);
  }
  const coreHubGho = new Map<number, CoreHubGho>();
  for (const spec of listEnv(env, "MONITOR_CORE_HUB_GHO")) {
    const [key, hub, assetId] = spec.split(":");
    if (!assetId || !/^\d+$/.test(assetId)) throw new Error(`MONITOR_CORE_HUB_GHO entry ${spec} is not chain:hub:assetId`);
    coreHubGho.set(chainOf(key, "MONITOR_CORE_HUB_GHO", spec), { hub: address(hub, "MONITOR_CORE_HUB_GHO", spec), assetId: BigInt(assetId) });
  }
  const frontendUrl = optionalEnv(env, "MONITOR_FRONTEND_URL");
  if (frontendUrl && !frontendUrl.startsWith("https://")) throw new Error("MONITOR_FRONTEND_URL must be https");
  const frontendChain = optionalEnv(env, "MONITOR_FRONTEND_CHAIN") ?? chains[0]!.chain.key;
  const frontend = frontendUrl
    ? { url: frontendUrl, expectedSha256: optionalEnv(env, "MONITOR_FRONTEND_SHA256") ?? null, chainId: chainOf(frontendChain, "MONITOR_FRONTEND_CHAIN", frontendChain) }
    : null;

  return {
    chains,
    intervalSeconds: optionalEnv(env, "MONITOR_INTERVAL_SECONDS") ? intEnv(env, "MONITOR_INTERVAL_SECONDS") : 12,
    channels,
    routing,
    incidentLogPath: requireEnv(env, "MONITOR_INCIDENT_LOG"),
    statePath: requireEnv(env, "MONITOR_STATE_PATH"),
    port: optionalEnv(env, "MONITOR_PORT") ? intEnv(env, "MONITOR_PORT") : 9470,
    statusToken: requireEnv(env, "MONITOR_STATUS_TOKEN"),
    keeperInstances,
    keeperTokens,
    safes,
    routeCheckSeconds: (optionalEnv(env, "MONITOR_ROUTE_CHECK_HOURS") ? intEnv(env, "MONITOR_ROUTE_CHECK_HOURS") : 24) * 3_600,
    liveness: {
      periodSeconds: (optionalEnv(env, "MONITOR_LIVENESS_PERIOD_HOURS") ? intEnv(env, "MONITOR_LIVENESS_PERIOD_HOURS") : 24) * 3_600,
      windowSeconds: (optionalEnv(env, "MONITOR_LIVENESS_WINDOW_HOURS") ? intEnv(env, "MONITOR_LIVENESS_WINDOW_HOURS") : 12) * 3_600,
    },
    coreHubGho,
    frontend,
  };
}
