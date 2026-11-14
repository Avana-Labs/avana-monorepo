// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The generated address library: built from verified manifests, ordered by release, and the committed file current.

import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { addressesFromManifest, compareReleases, deployedChainIds, getAddresses } from "../src/addresses/index.ts";
import { readAddressBook, renderAddressBook } from "../src/addresses/generate.ts";
import type { ReleaseManifest } from "../src/manifest/index.ts";
import { sampleManifest } from "./fixtures/manifest.ts";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const dirs: string[] = [];
afterEach(() => dirs.splice(0).forEach((d) => rmSync(d, { recursive: true, force: true })));

function deploymentsWith(files: Record<string, ReleaseManifest>): string {
  const root = mkdtempSync(join(tmpdir(), "avana-addresses-"));
  dirs.push(root);
  mkdirSync(join(root, "verified"));
  for (const [name, m] of Object.entries(files)) writeFileSync(join(root, "verified", name), JSON.stringify(m));
  return root;
}

describe("address library", () => {
  it("takes every contract address from the manifest", () => {
    const m = sampleManifest();
    const a = addressesFromManifest(m);
    expect(a.chainId).toBe(m.chainId);
    expect(a.release).toBe(m.release);
    expect(a.contracts.aaveAdapter).toBe(m.avana.aaveAdapter.address);
    expect(a.contracts.lens).toBe(m.avana.lens.address);
    expect(a.markets.map((k) => k.vaultToken)).toEqual(m.markets.map((k) => k.vaultToken.address));
    expect(a.debtReserves.map((r) => r.debtReserveId)).toEqual(m.debtReserves.map((r) => r.debtReserveId));
    expect(a.aave.hubs.map((h) => h.address)).toEqual(m.aave.hubs.map((h) => h.address));
  });

  it("orders releases by version, pre-releases first", () => {
    const tags = ["v1.10.0", "v1.0.0", "v0.1.0-alpha.2", "v1.0.0-rc.1", "v0.1.0-alpha.10", "v1.9.1", "v0.1.0-alpha.1"];
    expect([...tags].sort(compareReleases)).toEqual(["v0.1.0-alpha.1", "v0.1.0-alpha.2", "v0.1.0-alpha.10", "v1.0.0-rc.1", "v1.0.0", "v1.9.1", "v1.10.0"]);
  });

  it("groups verified manifests by chain with the newest release as latest", () => {
    const m = sampleManifest();
    const book = readAddressBook(
      deploymentsWith({
        [`sepolia-v1.0.0.json`]: m,
        [`sepolia-v1.1.0-rc.1.json`]: { ...m, release: "v1.1.0-rc.1" },
        [`sepolia-v0.9.0.json`]: { ...m, release: "v0.9.0" },
      }),
    );
    expect(Object.keys(book.deployments)).toEqual([String(m.chainId)]);
    expect(Object.keys(book.deployments[m.chainId]!)).toEqual(["v0.9.0", "v1.0.0", "v1.1.0-rc.1"]);
    expect(book.latest[m.chainId]).toBe("v1.1.0-rc.1");
    expect(renderAddressBook(book)).toContain(`"aaveAdapter": "${m.avana.aaveAdapter.address}"`);
  });

  it("refuses a manifest whose file name does not match it, or one that fails the schema", () => {
    expect(() => readAddressBook(deploymentsWith({ "base-v1.0.0.json": sampleManifest() }))).toThrow(/must be sepolia-v1\.0\.0\.json/);
    const bad = { ...sampleManifest(), abiHash: "0x1234" } as unknown as ReleaseManifest;
    expect(() => readAddressBook(deploymentsWith({ "sepolia-v1.0.0.json": bad }))).toThrow(/abiHash/);
  });

  it("is empty without verified manifests", () => {
    const book = readAddressBook(join(tmpdir(), "avana-no-deployments-here"));
    expect(book).toEqual({ deployments: {}, latest: {} });
  });

  it("the committed generated.ts matches deployments/verified/", () => {
    const committed = readFileSync(join(REPO, "packages/protocol/src/addresses/generated.ts"), "utf8");
    expect(committed).toBe(renderAddressBook(readAddressBook(join(REPO, "deployments"))));
  });

  it("looks up the committed library by chain", () => {
    for (const chainId of deployedChainIds()) expect(getAddresses(chainId)?.chainId).toBe(chainId);
    expect(getAddresses(999_999_999)).toBeUndefined();
  });
});
