// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The verified manifests the indexer runs on (AVANA_MANIFEST), loaded on first use, and the lookups the handlers make
// in them: the integration a RiskModule belongs to and the LPVault of an AaveAdapter. Tests set the manifests with
// `useManifests` instead of the environment.

import { ABI_HASH } from "@avana/protocol/abis";
import { type ServiceManifest, aaveTopology, listEnv, loadManifest } from "@avana/services-common";

let loaded: Map<number, ServiceManifest> | null = null;

/** Every manifest by chain ID; each is refused at load without a Hub or a Lend Spoke. */
export function manifests(): ReadonlyMap<number, ServiceManifest> {
  loaded ??= new Map(
    listEnv(process.env, "AVANA_MANIFEST").map((path) => {
      const m = loadManifest(path, ABI_HASH);
      aaveTopology(m);
      return [m.chainId, m] as const;
    }),
  );
  return loaded;
}

/** Replaces the manifests (tests). */
export function useManifests(ms: readonly ServiceManifest[]): void {
  loaded = new Map(ms.map((m) => [m.chainId, m]));
}

const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/** The integration a RiskModule belongs to, with its kind; undefined for another address. */
export function integrationOfRiskModule(chainId: number, riskModule: string): { integrationId: number; kind: string } | undefined {
  const x = manifests().get(chainId)?.avana.integrations.find((i) => same(i.riskModule.address, riskModule));
  return x ? { integrationId: x.integrationId, kind: x.kind } : undefined;
}

/** The LPVault of an AaveAdapter's integration; undefined for another address. */
export function lpVaultOfAdapter(chainId: number, adapter: string): `0x${string}` | undefined {
  const x = manifests().get(chainId)?.avana.integrations.find((i) => same(i.aaveAdapter.address, adapter));
  return x ? (x.lpVault.address.toLowerCase() as `0x${string}`) : undefined;
}

/** The address a bytes32 pool key holds for a concentrated-liquidity integration (the address left-padded). */
export const poolAddressOf = (pool: string): `0x${string}` => `0x${pool.slice(-40)}`.toLowerCase() as `0x${string}`;
