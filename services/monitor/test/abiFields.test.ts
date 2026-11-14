// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The probes read the protocol through names; the scripted chain answers whatever is asked. This checks every
// function, output field and event name the probes use against the ABIs the service is built with, so a rename in
// the contracts fails here instead of in production.

import { describe, expect, it } from "vitest";
import { debtOracleAbi, lensAbi, lpOracleAbi, parameterStoreAbi } from "@avana/protocol/abis";
import type { Abi } from "viem";
import { BACKING_FLAGS } from "../src/probes/coverage.ts";
import { EVENT_NAMES, TOPIC_COUNT } from "../src/probes/events.ts";

function outputs(abi: Abi, fn: string): string[] {
  const f = abi.find((e) => e.type === "function" && e.name === fn) as Extract<Abi[number], { type: "function" }> | undefined;
  if (!f) throw new Error(`no function ${fn}`);
  // A single tuple output decodes to its fields; several outputs to their names.
  const only = f.outputs[0] as { type: string; components?: readonly { name?: string }[] } | undefined;
  if (f.outputs.length === 1 && only?.type === "tuple") return only.components!.map((c) => c.name!);
  return f.outputs.map((o) => o.name ?? "");
}

describe("protocol names the probes read", () => {
  const cases: [string, Abi, string, string[]][] = [
    ["LPOracle", lpOracleAbi as Abi, "getPriceState", ["usdLevel", "disagreeSince"]],
    ["ParameterStore", parameterStoreAbi as Abi, "getOracleConfig", ["usdBandLow", "disagreementPauseMax"]],
    ["ParameterStore", parameterStoreAbi as Abi, "getFeed", ["feedMaxAge"]],
    ["Lens", lensAbi as Abi, "getDebtPriceState", ["state", "age", "fixedPrice"]],
    ["Lens", lensAbi as Abi, "getCapHeadroom", ["poolShareBps", "poolShareMaxBps"]],
    ["Lens", lensAbi as Abi, "checkBacking", [...BACKING_FLAGS]],
    ["Lens", lensAbi as Abi, "getTailCoverage", ["funded", "minimum", "ratioBps", "deficitOffset", "offsetFunded"]],
    ["Lens", lensAbi as Abi, "getHubAsset", ["baseDrawnRateBps"]],
    ["DebtOracle", debtOracleAbi as Abi, "borrowPriceMaxAge", [""]],
    ["DebtOracle", debtOracleAbi as Abi, "liquidationPriceMaxAge", [""]],
  ];
  for (const [contract, abi, fn, fields] of cases) {
    it(`${contract}.${fn} has ${fields.filter(Boolean).join(", ") || "its output"}`, () => {
      const names = outputs(abi, fn);
      for (const f of fields) if (f) expect(names).toContain(f);
    });
  }

  it("checkBacking reports exactly the backing flags the probe requires", () => {
    const bools = ((lensAbi as Abi).find((e) => e.type === "function" && e.name === "checkBacking") as unknown as { outputs: { components: { name: string; type: string }[] }[] }).outputs[0]!.components.filter((c) => c.type === "bool").map((c) => c.name);
    expect([...BACKING_FLAGS].sort()).toEqual(bools.sort());
  });

  it("finds a topic for every event the events probe reads", () => {
    expect(TOPIC_COUNT).toBe(EVENT_NAMES.length);
  });
});
