// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The snapshot reader's ABI fragments (@avana/services-common/views) against the ABIs generated from the release
// build: same selector and same output layout, struct fields included, so a field added to a RiskModule, LPOracle,
// First-Loss Reserve, Hub or Spoke struct fails here instead of shifting every decoded field.

import { describe, expect, it } from "vitest";
import { type Abi, type AbiFunction, type AbiParameter, toFunctionSelector } from "viem";
import { aaveV4HubAbi, aaveV4SpokeAbi, firstLossReserveAbi, lpOracleAbi, riskModuleAbi } from "@avana/protocol/abis";
import { firstLossReserveViewsAbi, hubViewsAbi, lpOracleViewsAbi, riskModuleViewsAbi, spokeViewsAbi } from "@avana/services-common/views";

function layout(p: AbiParameter): string {
  if (!p.type.startsWith("tuple")) return p.type;
  const components = (p as { components: readonly AbiParameter[] }).components.map(layout).join(",");
  return `(${components})${p.type.slice("tuple".length)}`;
}

const fns = (abi: Abi | readonly unknown[]) => (abi as Abi).filter((i): i is AbiFunction => i.type === "function");

function compare(fragment: readonly unknown[], generated: Abi | readonly unknown[]) {
  const bySelector = new Map(fns(generated).map((f) => [toFunctionSelector(f), f]));
  const differing: string[] = [];
  for (const f of fns(fragment)) {
    const g = bySelector.get(toFunctionSelector(f));
    if (!g || g.outputs.map(layout).join("|") !== f.outputs.map(layout).join("|")) differing.push(f.name);
  }
  expect(differing).toEqual([]);
}

describe("snapshot ABI fragments", () => {
  it("match the Aave V4 Hub views", () => compare(hubViewsAbi, aaveV4HubAbi));
  it("match the Aave V4 Spoke views", () => compare(spokeViewsAbi, aaveV4SpokeAbi));
  it("match the RiskModule's market and coverage views", () => compare(riskModuleViewsAbi, riskModuleAbi));
  it("match the LPOracle's price views", () => compare(lpOracleViewsAbi, lpOracleAbi));
  it("match the First-Loss Reserve's balance view", () => compare(firstLossReserveViewsAbi, firstLossReserveAbi));
});
