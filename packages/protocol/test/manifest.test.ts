// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Release manifest schema, validator and contract table.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { contractTable, parseManifest, releaseManifestSchema, validate } from "../src/manifest/index.ts";
import { integrationArtifacts } from "../src/manifest/produce.ts";
import { A, H, sampleManifest } from "./fixtures/manifest.ts";

describe("release manifest schema", () => {
  it("accepts a complete manifest", () => {
    expect(validate(sampleManifest())).toEqual([]);
  });

  it("names every missing, malformed or unknown field", () => {
    const m = structuredClone(sampleManifest()) as Record<string, any>;
    delete m.feeRecipient;
    m.avana.accessManager.address = "0x1234";
    m.markets[0].kind = "narrow";
    m.extra = 1;
    const paths = validate(m).map((e) => e.path);
    expect(paths).toContain("$.feeRecipient");
    expect(paths).toContain("$.avana.accessManager.address");
    expect(paths).toContain("$.markets[0].kind");
    expect(paths).toContain("$.extra");
  });

  it("refuses a release that is not a semantic version tag and an unknown network", () => {
    const m = { ...sampleManifest(), release: "latest", network: "mainnet" };
    expect(validate(m).map((e) => e.path)).toEqual(["$.network", "$.release"]);
  });

  it("refuses the schema 1 manifest of the replaced contracts", () => {
    expect(() => parseManifest(JSON.stringify({ ...sampleManifest(), schemaVersion: 1 }))).toThrow(/schemaVersion/);
  });

  it("holds each pool to one Full range and one Custom range market with the same LTV", () => {
    const m = structuredClone(sampleManifest()) as Record<string, any>;
    m.markets[1].kind = "full-range";
    m.markets[1].ltvBps = 8000;
    const paths = validate(m).map((e) => e.path);
    expect(paths).toContain("$.markets[1].kind");
    expect(paths).toContain("$.markets[1].ltvBps");
  });

  it("refuses a market of an unlisted integration, an inverted band and a pair of tokens that is not two", () => {
    const m = structuredClone(sampleManifest()) as Record<string, any>;
    m.markets[0].integrationId = 9;
    m.markets[1].bandLower = 200;
    m.markets[1].tokens = [A(60)];
    const paths = validate(m).map((e) => e.path);
    expect(paths).toContain("$.markets[0].integrationId");
    expect(paths).toContain("$.markets[1].bandUpper");
    expect(paths).toContain("$.markets[1].tokens");
  });

  it("takes a keeper top-up wallet or null", () => {
    const m = structuredClone(sampleManifest()) as Record<string, any>;
    m.roles.keeperTopUpWallet = null;
    expect(validate(m)).toEqual([]);
    delete m.roles.keeperTopUpWallet;
    expect(validate(m).map((e) => e.path)).toEqual(["$.roles.keeperTopUpWallet"]);
  });

  it("accepts a Uniswap v4 integration with its PoolManager, and the PoolManager is optional", () => {
    const m = structuredClone(sampleManifest()) as Record<string, any>;
    m.avana.integrations.push({ ...m.avana.integrations[0], integrationId: 3, kind: "uniswap-v4" });
    m.uniswapV4 = { poolManager: { address: A(70), codeHash: H(70), startBlock: 5, artifact: null } };
    expect(validate(m)).toEqual([]);
    delete m.uniswapV4;
    expect(validate(m)).toEqual([]);
  });

  it("refuses an unknown integration kind and a malformed Uniswap v4 PoolManager", () => {
    const m = structuredClone(sampleManifest()) as Record<string, any>;
    m.avana.integrations[0].kind = "curve";
    m.uniswapV4 = { poolManager: { address: A(70) } };
    const paths = validate(m).map((e) => e.path);
    expect(paths).toContain("$.avana.integrations[0].kind");
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
  it("lists every contract with its explorer link and code hash, grouped by integration, and marks stand-ins", () => {
    const md = contractTable(sampleManifest());
    expect(md).toContain("# Avana v1.0.0 on sepolia");
    expect(md).toContain(`[${A(13)}](https://sepolia.etherscan.io/address/${A(13)})`);
    expect(md).toContain("## Avana integration 1 (uniswap-v3)");
    expect(md).toContain("Vault token, market 2 (USDC-USDT-100 custom)");
    expect(md).toContain("First-Loss Reserve stable USDC");
    expect(md).toContain("USDC (test-network stand-in)");
    expect(md).toContain(H(11));
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
});
