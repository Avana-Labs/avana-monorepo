// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The indexer's sources from a manifest with three Hubs, three Lend Spokes and two CDP Spokes: every Hub and Spoke of
// the manifest is followed from its deployment block, Hubs the MarketRegistry records later, CDP Spokes it approves
// later and Spokes a manifest Hub adds later are followed through the events that announce them, and the series
// sampler starts from all of them.

import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { ABI_HASH } from "@avana/protocol/abis";
import { sampleManifest } from "@avana/protocol/manifest/sample";
import { chainById, rpcEnvName } from "@avana/services-common";

const SEPOLIA = 11_155_111;
const addr = (n: number) => `0x${n.toString(16).padStart(40, "0")}`;
const hash = `0x${"00".repeat(32)}`;
const up = (n: number, startBlock: number) => ({ address: addr(n), codeHash: hash, implementation: addr(n + 0x1000), implementationCodeHash: hash, implementationArtifact: "X.sol:X", logics: [], startBlock });
const im = (n: number, startBlock: number) => ({ address: addr(n), codeHash: hash, startBlock, artifact: null });

// A complete manifest (the services validate it against the release schema) with the Hubs, Spokes and contracts
// these tests follow.
const sample = sampleManifest();
const manifest = {
  ...sample,
  chainId: SEPOLIA,
  release: "v1.0.0-test",
  abiHash: ABI_HASH,
  avana: {
    ...sample.avana,
    lens: im(0x10, 120),
    marketRegistry: up(0x11, 100),
    vaultTokenFactory: im(0x12, 100),
    firstLossReserves: [{ ...im(0x41, 130), asset: addr(0x51), hub: addr(0x21) }],
  },
  aave: {
    ...sample.aave,
    hubs: [{ ...up(0x21, 90), label: "Stable LP", tier: 1 }, { ...up(0x22, 95), label: "Core", tier: 2 }, { ...up(0x23, 97), label: "Growth", tier: 3 }],
    borrowSpokes: [{ ...up(0x31, 110), label: "Stable LP Uniswap v3" }, { ...up(0x32, 111), label: "Core Slipstream" }],
    lendSpokes: [{ ...up(0x33, 125), label: "Stable LP" }, { ...up(0x34, 140), label: "Core" }, { ...up(0x35, 150), label: "Growth" }],
  },
};

const dir = mkdtempSync(join(tmpdir(), "avana-sources-"));
let sources: typeof import("../src/config/sources.ts");

beforeAll(async () => {
  const path = join(dir, "sepolia.json");
  writeFileSync(path, JSON.stringify(manifest));
  const chain = chainById(SEPOLIA);
  process.env.INDEXER_NETWORK_SET = "testnet";
  process.env.AVANA_MANIFEST = path;
  process.env[rpcEnvName(chain, "PRIMARY")] = "http://127.0.0.1:1";
  process.env[rpcEnvName(chain, "FALLBACK")] = "http://127.0.0.1:2";
  sources = await import("../src/config/sources.ts");
});
afterAll(() => rmSync(dir, { recursive: true, force: true }));

describe("indexer sources with several Hubs", () => {
  it("follows every manifest Hub and every Lend and CDP Spoke from its own deployment block", () => {
    expect(sources.hubSource().sepolia).toEqual({ address: [addr(0x21), addr(0x22), addr(0x23)], startBlock: 90 });
    expect(sources.spokeSource().sepolia).toEqual({ address: [addr(0x31), addr(0x32), addr(0x33), addr(0x34), addr(0x35)], startBlock: 110 });
  });

  it("follows Hubs recorded and CDP Spokes approved later through the MarketRegistry, from its deployment", () => {
    const hubs = sources.hubRecordedSource().sepolia!;
    const spokes = sources.spokeApprovedSource().sepolia!;
    expect([hubs.startBlock, spokes.startBlock]).toEqual([100, 100]);
    expect(hubs.address).toMatchObject({ address: addr(0x11), parameter: "hub", event: { name: "HubRecorded" } });
    expect(spokes.address).toMatchObject({ address: addr(0x11), parameter: "spoke", event: { name: "SpokeApproved" } });
  });

  it("follows every Spoke a manifest Hub adds later, a Lend Spoke included", () => {
    const added = sources.spokeAddedSource().sepolia!;
    expect(added.startBlock).toBe(90);
    expect(added.address).toMatchObject({ address: [addr(0x21), addr(0x22), addr(0x23)], parameter: "spoke", event: { name: "AddSpoke" } });
  });

  it("gives the sampler every Hub, Lend Spoke, CDP Spoke and the registry, and starts it at the first Lend Spoke", () => {
    expect(sources.deploymentOf(SEPOLIA)).toEqual({
      chainId: SEPOLIA,
      lens: addr(0x10),
      marketRegistry: addr(0x11),
      hubs: [
        { address: addr(0x21), label: "Stable LP" },
        { address: addr(0x22), label: "Core" },
        { address: addr(0x23), label: "Growth" },
      ],
      lendSpokes: [addr(0x33), addr(0x34), addr(0x35)],
      cdpSpokes: [addr(0x31), addr(0x32)],
      firstLossReserves: [{ address: addr(0x41), asset: addr(0x51), hub: addr(0x21) }],
    });
    expect(sources.samplerSource().sepolia).toMatchObject({ startBlock: 125 });
  });
});
