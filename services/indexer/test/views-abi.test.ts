// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The snapshot reader's ABI fragments (@avana/services-common/views) against the ABIs generated from the release
// build: same selector and same output layout, struct fields included, so a field added to a Lens, registry, Hub or
// Spoke struct fails here instead of shifting every decoded field. Lens views the committed ABI does not hold yet, or
// holds in an older layout than contracts/src/lens/lens/, are listed by name; regenerating the ABI from a build that
// has them fails this test until the list is emptied.

import { describe, expect, it } from "vitest";
import { type Abi, type AbiFunction, type AbiParameter, toFunctionSelector } from "viem";
import { aaveV4HubAbi, aaveV4SpokeAbi, lensAbi, marketRegistryAbi } from "@avana/protocol/abis";
import { hubViewsAbi, lensViewsAbi, registryViewsAbi, spokeViewsAbi } from "@avana/services-common/views";

/**
 * Round-1 Lens views whose committed ABI predates the source: `getMarkets` and `getDebtReserves` (ILensMarkets.sol)
 * are absent, and `getHubAssetExposure` lacks the `blockNumber` and `timestamp` its struct now starts with.
 */
const NOT_YET_GENERATED = new Set(["getMarkets", "getDebtReserves", "getHubAssetExposure"]);

function layout(p: AbiParameter): string {
  if (!p.type.startsWith("tuple")) return p.type;
  const components = (p as { components: readonly AbiParameter[] }).components.map(layout).join(",");
  return `(${components})${p.type.slice("tuple".length)}`;
}

const fns = (abi: Abi | readonly unknown[]) => (abi as Abi).filter((i): i is AbiFunction => i.type === "function");

function compare(fragment: readonly unknown[], generated: Abi | readonly unknown[], pending: ReadonlySet<string> = new Set()) {
  const bySelector = new Map(fns(generated).map((f) => [toFunctionSelector(f), f]));
  const differing: string[] = [];
  for (const f of fns(fragment)) {
    const g = bySelector.get(toFunctionSelector(f));
    if (!g || g.outputs.map(layout).join("|") !== f.outputs.map(layout).join("|")) differing.push(f.name);
  }
  expect(new Set(differing)).toEqual(new Set(pending));
}

describe("snapshot ABI fragments", () => {
  it("match the Aave V4 Hub views", () => compare(hubViewsAbi, aaveV4HubAbi));
  it("match the Aave V4 Spoke views", () => compare(spokeViewsAbi, aaveV4SpokeAbi));
  it("match the Lens views, apart from those listed as not yet generated", () => compare(lensViewsAbi, lensAbi, NOT_YET_GENERATED));
  it("match the MarketRegistry Hub, Spoke and credit-line views", () => compare(registryViewsAbi, marketRegistryAbi));
});
