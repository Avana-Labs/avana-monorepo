// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Release manifest schema, validator and contract table.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { contractTable, parseManifest, releaseManifestSchema, validate } from "../src/manifest/index.ts";
import { sampleManifest } from "../src/manifest/sample.ts";

const A = (n: number) => `0x${n.toString(16).padStart(40, "0")}`;
const H = (n: number) => `0x${n.toString(16).padStart(64, "0")}`;

describe("release manifest schema", () => {
  it("accepts a complete manifest", () => {
    expect(validate(sampleManifest())).toEqual([]);
  });

  it("names every missing, malformed or unknown field", () => {
    const m = structuredClone(sampleManifest()) as Record<string, any>;
    delete m.feeRecipient;
    m.avana.lock.address = "0x1234";
    m.roles.timelock.normalDelay = 3600;
    m.extra = 1;
    const paths = validate(m).map((e) => e.path);
    expect(paths).toContain("$.feeRecipient");
    expect(paths).toContain("$.avana.lock.address");
    expect(paths).toContain("$.roles.timelock.normalDelay");
    expect(paths).toContain("$.extra");
  });

  it("refuses a release that is not a semantic version tag and an unknown network", () => {
    const m = { ...sampleManifest(), release: "latest", network: "mainnet" };
    expect(validate(m).map((e) => e.path)).toEqual(["$.network", "$.release"]);
  });

  it("parseManifest throws with the list of failures", () => {
    expect(() => parseManifest(JSON.stringify({ schemaVersion: 2 }))).toThrow(/schemaVersion/);
  });

  it("the committed schema file is the schema object", () => {
    const root = join(dirname(fileURLToPath(import.meta.url)), "../../..");
    const committed = JSON.parse(readFileSync(join(root, "deployments/release-manifest.schema.json"), "utf8"));
    expect(committed).toEqual(JSON.parse(JSON.stringify(releaseManifestSchema)));
  });
});

describe("contract table", () => {
  it("lists every contract with its explorer link, proxy target and code hash, and marks stand-ins", () => {
    const md = contractTable(sampleManifest());
    expect(md).toContain("# Avana v1.0.0 on sepolia");
    expect(md).toContain(`[${A(10)}](https://sepolia.etherscan.io/address/${A(10)})`);
    expect(md).toContain(`ERC-1967 proxy → ${A(1010)}`);
    expect(md).toContain("AaveAdapter · AaveAdapterUserLogic");
    expect(md).toContain("USDC (test-network stand-in)");
    expect(md).toContain(H(25));
  });
});
