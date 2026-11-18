// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Release manifest schema, validator and contract table.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { contractTable, parseManifest, releaseManifestSchema, validate } from "../src/manifest/index.ts";
import { integrationArtifacts } from "../src/manifest/produce.ts";
import { profileOf } from "../src/manifest/verify.ts";
import { A, H, sampleManifest } from "./fixtures/manifest.ts";

describe("release manifest schema", () => {
  it("accepts a complete manifest", () => {
    expect(validate(sampleManifest())).toEqual([]);
  });

  it("names every missing, malformed or unknown field", () => {
    const m = structuredClone(sampleManifest()) as Record<string, any>;
    delete m.feeRecipient;
    m.avana.lock.address = "0x1234";
    m.roles.timelock.normalDelay = 30;
    m.extra = 1;
    const paths = validate(m).map((e) => e.path);
    expect(paths).toContain("$.feeRecipient");
    expect(paths).toContain("$.avana.lock.address");
    expect(paths).toContain("$.roles.timelock.normalDelay");
    expect(paths).toContain("$.extra");
  });

  it("takes a normal delay of minutes on a test network only (REQ-ACCESS-187)", () => {
    const m = structuredClone(sampleManifest()) as Record<string, any>;
    m.roles.timelock.normalDelay = 120;
    expect(validate({ ...m, chainId: 11155111 })).toEqual([]);
    expect(validate({ ...m, chainId: 84532 })).toEqual([]);
    expect(validate({ ...m, chainId: 1, network: "ethereum" }).map((e) => e.path)).toEqual(["$.roles.timelock.normalDelay"]);
    expect(validate({ ...m, chainId: 8453, network: "base" }).map((e) => e.path)).toEqual(["$.roles.timelock.normalDelay"]);
    m.roles.timelock.normalDelay = 345600;
    expect(validate({ ...m, chainId: 1, network: "ethereum" })).toEqual([]);
  });

  it("refuses a release that is not a semantic version tag and an unknown network", () => {
    const m = { ...sampleManifest(), release: "latest", network: "mainnet" };
    expect(validate(m).map((e) => e.path)).toEqual(["$.network", "$.release"]);
  });

  it("takes the gas vault with its immutables, or null before step 12-gas-vault", () => {
    const m = structuredClone(sampleManifest()) as Record<string, any>;
    expect(validate(m)).toEqual([]);
    m.avana.gasVault = null;
    expect(validate(m)).toEqual([]);
    m.avana.gasVault = { ...sampleManifest().avana.gasVault, maxSigners: 9 };
    expect(validate(m).map((e) => e.path)).toEqual(["$.avana.gasVault"]);
    delete m.avana.gasVault;
    expect(validate(m).map((e) => e.path)).toEqual(["$.avana.gasVault"]);
  });

  it("parseManifest throws with the list of failures", () => {
    expect(() => parseManifest(JSON.stringify({ schemaVersion: 2 }))).toThrow(/schemaVersion/);
  });

  it("accepts a Uniswap v4 integration with its PoolManager, and the PoolManager is optional", () => {
    const m = structuredClone(sampleManifest()) as Record<string, any>;
    m.avana.lpVaults.push({ ...m.avana.lock, integrationId: 3, kind: "uniswap-v4" });
    m.uniswapV4 = { poolManager: { address: A(70), codeHash: H(70), startBlock: 5, artifact: null } };
    m.external.push({ name: "PoolManager", group: "uniswap-v4", address: A(70), codeHash: H(70), implementation: null, standIn: false });
    expect(validate(m)).toEqual([]);
    delete m.uniswapV4;
    expect(validate(m)).toEqual([]);
  });

  it("refuses an unknown integration kind and a malformed Uniswap v4 PoolManager", () => {
    const m = structuredClone(sampleManifest()) as Record<string, any>;
    m.avana.lpVaults[0].kind = "curve";
    m.uniswapV4 = { poolManager: { address: A(70) } };
    const paths = validate(m).map((e) => e.path);
    expect(paths).toContain("$.avana.lpVaults[0].kind");
    expect(paths).toContain("$.uniswapV4.poolManager.codeHash");
    expect(paths).toContain("$.uniswapV4.poolManager.startBlock");
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

  it("labels the Uniswap v4 group", () => {
    const m = structuredClone(sampleManifest()) as Record<string, any>;
    m.external.push({ name: "PoolManager", group: "uniswap-v4", address: A(70), codeHash: H(70), implementation: null, standIn: false });
    expect(contractTable(m as ReturnType<typeof sampleManifest>)).toContain("## Uniswap v4");
  });
});

describe("integration artifacts", () => {
  it("names the LPVault of each kind", () => {
    expect(integrationArtifacts("uniswap-v3")).toEqual({ lpVault: "UniswapV3Integration.sol:UniswapV3Integration" });
    expect(integrationArtifacts("slipstream").lpVault).toBe("SlipstreamIntegration.sol:SlipstreamIntegration");
    expect(integrationArtifacts("uniswap-v4")).toEqual({ lpVault: "UniswapV4Integration.sol:UniswapV4Integration" });
    expect(() => integrationArtifacts("curve")).toThrow(/unknown integration kind/);
  });

  it("maps each deployable file to its compiler profile as DeployBase._profileOf does", () => {
    expect(profileOf("UniswapV3Integration.sol")).toBe("clvault");
    expect(profileOf("SlipstreamIntegration.sol")).toBe("clvault");
    expect(profileOf("UniswapV4Integration.sol")).toBe("collateralization");
    expect(profileOf("LPOracle.sol")).toBe("lporacle");
    expect(profileOf("Lock.sol")).toBe("");
  });
});
