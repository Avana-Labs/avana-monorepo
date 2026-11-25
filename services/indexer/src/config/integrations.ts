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

/** A contract of an integration's core stack. */
export type StackRole = "riskModule" | "lpVault" | "aaveAdapter" | "liquidationModule" | "flashloanRepay";

/**
 * The integration whose core stack holds `address` as `role`, with its kind; undefined for another address. Market IDs
 * are numbered per RiskModule, so every event carrying a marketId is read with the integration of its emitter.
 */
export function integrationOfStack(chainId: number, role: StackRole, address: string): { integrationId: number; kind: string } | undefined {
  const x = manifests().get(chainId)?.avana.integrations.find((i) => same(i[role].address, address));
  return x ? { integrationId: x.integrationId, kind: x.kind } : undefined;
}

/** The integration a RiskModule belongs to, with its kind; undefined for another address. */
export function integrationOfRiskModule(chainId: number, riskModule: string): { integrationId: number; kind: string } | undefined {
  return integrationOfStack(chainId, "riskModule", riskModule);
}

/** The integration of a FlashLiquidator; undefined for another address. */
export function integrationOfFlashLiquidator(chainId: number, flashLiquidator: string): number | undefined {
  return manifests().get(chainId)?.avana.flashLiquidators.find((f) => same(f.address, flashLiquidator))?.integrationId;
}

/** `integrationOfStack` for an emitter the manifest must list: an unknown one stops the indexer (fail closed). */
export function stackIntegration(chainId: number, role: StackRole, address: string): number {
  const x = integrationOfStack(chainId, role, address);
  if (!x) throw new Error(`${role} ${address} on chain ${chainId} is not in the manifest`);
  return x.integrationId;
}

/** The LPVault of an AaveAdapter's integration; undefined for another address. */
export function lpVaultOfAdapter(chainId: number, adapter: string): `0x${string}` | undefined {
  const x = manifests().get(chainId)?.avana.integrations.find((i) => same(i.aaveAdapter.address, adapter));
  return x ? (x.lpVault.address.toLowerCase() as `0x${string}`) : undefined;
}

/** The address a bytes32 pool key holds for a concentrated-liquidity integration (the address left-padded). */
export const poolAddressOf = (pool: string): `0x${string}` => `0x${pool.slice(-40)}`.toLowerCase() as `0x${string}`;
