// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Contract addresses of every verified deployment, by chain, generated from deployments/verified/ (generated.ts).

import { DEPLOYMENTS, LATEST_RELEASE } from "./generated.ts";
import type { AvanaAddresses } from "./fromManifest.ts";

export { DEPLOYMENTS, LATEST_RELEASE } from "./generated.ts";
export { addressesFromManifest, compareReleases, type AvanaAddresses } from "./fromManifest.ts";

/** A chain ID with at least one verified deployment. */
export type DeployedChainId = keyof typeof DEPLOYMENTS;

const deployments: Readonly<Record<number, Readonly<Record<string, AvanaAddresses>>>> = DEPLOYMENTS;
const latest: Readonly<Record<number, string>> = LATEST_RELEASE;

/** Chain IDs with a verified deployment, ascending. */
export function deployedChainIds(): number[] {
  return Object.keys(deployments).map(Number);
}

/** The addresses of `release` on `chainId` (default: the chain's newest verified release), or undefined. */
export function getAddresses(chainId: number, release?: string): AvanaAddresses | undefined {
  const tag = release ?? latest[chainId];
  return tag === undefined ? undefined : deployments[chainId]?.[tag];
}

/** As `getAddresses`, but throws when the chain or release has no verified deployment. */
export function requireAddresses(chainId: number, release?: string): AvanaAddresses {
  const a = getAddresses(chainId, release);
  if (!a) throw new Error(`no verified Avana deployment${release ? ` ${release}` : ""} on chain ${chainId}`);
  return a;
}
