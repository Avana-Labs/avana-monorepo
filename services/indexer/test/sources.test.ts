// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The indexer's sources from a manifest with two integrations, three Hubs, three Lend Spokes and two CDP Spokes: each
// core contract kind is one source over every integration, every Hub and Spoke of the manifest is followed from its
// deployment block, vault tokens and First-Loss Reserves a RiskModule announces later and Spokes a manifest Hub adds
// later are followed through those events, the concentrated-liquidity pools of the manifest's markets are followed,
// and the series sampler starts from all of them.

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
const up = (n: number, startBlock: number) => ({ address: addr(n), codeHash: hash, implementation: addr(n + 0x1000), implementationCodeHash: hash, startBlock });
const im = (n: number, startBlock: number) => ({ address: addr(n), codeHash: hash, startBlock, artifact: null });
const stack = (id: number, kind: string, base: number, startBlock: number) => ({
  integrationId: id,
  kind,
  lpVault: im(base, startBlock),
  riskModule: im(base + 1, startBlock),
  liquidationModule: im(base + 2, startBlock),
  aaveAdapter: im(base + 3, startBlock),
  flashloanRepay: im(base + 4, startBlock + 1),
});
/** A v3 pool key: the pool address left-padded to 32 bytes. */
const POOL = `0x${"00".repeat(12)}${addr(0x70).slice(2)}`;

// A complete manifest (the services validate it against the release schema) with the Hubs, Spokes and contracts
// these tests follow.
const sample = sampleManifest();
const manifest = {
  ...sample,
  chainId: SEPOLIA,
  release: "v1.0.0-test",
  abiHash: ABI_HASH,
  avana: {
    accessManager: im(0x10, 100),
    integrations: [stack(1, "uniswap-v3", 0x100, 105), stack(3, "uniswap-v4", 0x300, 108)],
    flashLiquidators: [],
  },
  markets: sample.markets.map((m) => ({ ...m, pool: POOL, vaultToken: im(Number(m.vaultToken.address), 120) })),
  coverage: { firstLossReserves: [{ ...sample.coverage.firstLossReserves[0]!, ...im(0x41, 130) }], daoDeficitOffsets: [{ ...sample.coverage.daoDeficitOffsets[0]!, ...im(0x42, 135) }] },
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

describe("indexer sources", () => {
  it("covers each core contract kind of every integration with one source", () => {
    expect(sources.coreSource("aaveAdapter").sepolia).toEqual({ address: [addr(0x103), addr(0x303)], startBlock: 105 });
    expect(sources.coreSource("riskModule").sepolia).toEqual({ address: [addr(0x101), addr(0x301)], startBlock: 105 });
    expect(sources.coreSource("flashloanRepay").sepolia).toEqual({ address: [addr(0x104), addr(0x304)], startBlock: 106 });
  });

  it("follows every manifest Hub and every Lend and CDP Spoke from its own deployment block", () => {
    expect(sources.hubSource().sepolia).toEqual({ address: [addr(0x21), addr(0x22), addr(0x23)], startBlock: 90 });
    expect(sources.spokeSource().sepolia).toEqual({ address: [addr(0x31), addr(0x32), addr(0x33), addr(0x34), addr(0x35)], startBlock: 110 });
  });

  it("follows vault tokens and First-Loss Reserves every RiskModule announces later, from Avana's deployment", () => {
    const tokens = sources.vaultTokenSource().sepolia!;
    const reserves = sources.firstLossReserveSource().sepolia!;
    expect([tokens.startBlock, reserves.startBlock]).toEqual([100, 100]);
    expect(tokens.address).toMatchObject({ address: [addr(0x101), addr(0x301)], parameter: "vaultToken", event: { name: "MarketActivated" } });
    expect(reserves.address).toMatchObject({ address: [addr(0x101), addr(0x301)], parameter: "firstLossReserve", event: { name: "DebtReserveSet" } });
  });

  it("follows the manifest's vault tokens and loss layers from their deployment blocks", () => {
    expect(sources.vaultTokenListedSource().sepolia).toMatchObject({ startBlock: 120 });
    expect(sources.firstLossReserveListedSource()).toEqual({ sepolia: { address: [addr(0x41), addr(0x42)], startBlock: 130 } });
  });

  it("follows no flash liquidator on a chain whose manifest lists none", () => {
    expect(sources.flashLiquidatorSource()).toEqual({});
  });

  it("follows every Spoke a manifest Hub adds later, a Lend Spoke included", () => {
    const added = sources.spokeAddedSource().sepolia!;
    expect(added.startBlock).toBe(90);
    expect(added.address).toMatchObject({ address: [addr(0x21), addr(0x22), addr(0x23)], parameter: "spoke", event: { name: "AddSpoke" } });
  });

  it("follows the pool both markets of a concentrated-liquidity pool share, once", () => {
    expect(sources.ammPoolSource()).toEqual({ sepolia: { address: [addr(0x70)], startBlock: 100 } });
  });

  it("gives the sampler every Hub, Spoke, RiskModule and market, and starts it at the first Lend Spoke", () => {
    const d = sources.deploymentOf(SEPOLIA);
    expect(d.hubs.map((h) => [h.address, h.label, h.tier])).toEqual([
      [addr(0x21), "Stable LP", 1],
      [addr(0x22), "Core", 2],
      [addr(0x23), "Growth", 3],
    ]);
    expect(d.lendSpokes).toEqual([addr(0x33), addr(0x34), addr(0x35)]);
    expect(d.riskModules).toEqual([addr(0x101), addr(0x301)]);
    expect(d.markets.map((m) => [m.marketId, m.kind, m.riskModule])).toEqual([
      [1n, "full-range", addr(0x101)],
      [2n, "custom-range", addr(0x101)],
    ]);
    expect(sources.samplerSource().sepolia).toMatchObject({ startBlock: 125 });
  });

  it("maps a RiskModule to its integration and an AaveAdapter to its LPVault", () => {
    expect(sources.integrationOfRiskModule(SEPOLIA, addr(0x301))).toEqual({ integrationId: 3, kind: "uniswap-v4" });
    expect(sources.integrationOfRiskModule(SEPOLIA, addr(0x999))).toBeUndefined();
    expect(sources.lpVaultOfAdapter(SEPOLIA, addr(0x103))).toBe(addr(0x100));
  });

  it("follows no PoolManager on a chain whose manifest names none", () => {
    expect(sources.poolManagerSource()).toEqual({});
  });

  it("follows a manifest's PoolManager from the later of its deployment and Avana's", () => {
    const pm = (startBlock: number) => ({ uniswapV4: { poolManager: { address: addr(0x44), startBlock } }, avana: { accessManager: { startBlock: 100 } } }) as never;
    expect(sources.poolManagerOf(pm(50))).toEqual({ address: addr(0x44), startBlock: 100 });
    expect(sources.poolManagerOf(pm(150))).toEqual({ address: addr(0x44), startBlock: 150 });
    expect(sources.poolManagerOf({ avana: { accessManager: { startBlock: 100 } } } as never)).toBeNull();
  });
});
