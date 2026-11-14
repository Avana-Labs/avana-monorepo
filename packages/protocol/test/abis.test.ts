// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The committed ABIs and ABI_HASH must agree: a hand edit to one ABI file without regenerating changes the hash
// the services compare with each release manifest, so it fails here instead of at a service's startup.

import { describe, expect, it } from "vitest";
import { keccak256, stringToBytes, toEventSelector, toFunctionSelector, type Abi } from "viem";
import * as abis from "../src/abis/index.ts";

const { ABI_ARTIFACTS, ABI_HASH, ...exported } = abis;
const byExport = exported as unknown as Record<string, Abi>;

describe("generated ABIs", () => {
  it("ABI_HASH is keccak256 of the canonical JSON of every ABI, keyed by artifact name", () => {
    const artifacts = Object.entries(ABI_ARTIFACTS).map(([exportName, artifact]) => [artifact, byExport[exportName]] as const);
    const canonical = JSON.stringify(Object.fromEntries([...artifacts].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))));
    expect(keccak256(stringToBytes(canonical))).toBe(ABI_HASH);
  });

  it("exports exactly the ABIs listed in ABI_ARTIFACTS", () => {
    expect(Object.keys(byExport).sort()).toEqual(Object.keys(ABI_ARTIFACTS).sort());
  });

  it("no ABI declares two different items under one selector", () => {
    for (const [name, abi] of Object.entries(byExport)) {
      const seen = new Map<string, string>();
      for (const item of abi) {
        if (item.type !== "function" && item.type !== "event") continue;
        const selector = item.type === "event" ? toEventSelector(item) : toFunctionSelector(item);
        const signature = `${item.name}(${item.inputs.map((i) => i.type).join(",")})`;
        expect(seen.get(selector) ?? signature, `${name}: ${selector}`).toBe(signature);
        seen.set(selector, signature);
      }
    }
  });

  it("carries the timelock and First-Loss Reserve events their interfaces leave out", () => {
    const events = (abi: Abi) => abi.filter((i) => i.type === "event").map((i) => i.name);
    expect(events(abis.avanaTimelockAbi)).toEqual(expect.arrayContaining(["CallScheduled", "CallExecuted", "Cancelled", "RoleGranted"]));
    expect(events(abis.firstLossReserveAbi)).toEqual(expect.arrayContaining(["BorrowSpokeAllowlistUpdated", "FirstLossReserveMinimumUpdated"]));
  });
});
