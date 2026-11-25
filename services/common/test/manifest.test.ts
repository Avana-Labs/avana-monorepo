// loadManifest: a service refuses a manifest that does not match the release manifest schema or was built for other
// ABIs, and uint256 IDs stored as decimal strings come back as bigint without loss above 2^53. aaveTopology: the Hubs
// and Spokes of a manifest with several Hubs, in the shape packages/protocol writes (labelled Hubs with a tier,
// labelled Lend and Borrow Spokes).

import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { sampleManifest } from "@avana/protocol/manifest/sample";
import { aaveTopology, loadManifest, uniswapV4PoolManager } from "../src/manifest.ts";
import { chainDeploymentOf } from "../src/views/deployment.ts";

const ABI_HASH = `0x${"ab".repeat(32)}` as const;
const dir = mkdtempSync(join(tmpdir(), "avana-manifest-"));
afterAll(() => rmSync(dir, { recursive: true, force: true }));

function write(name: string, body: unknown): string {
  const path = join(dir, name);
  writeFileSync(path, JSON.stringify(body));
  return path;
}

const BIG_ID = "18446744073709551617"; // 2^64 + 1: not representable as a JavaScript number

const sample = sampleManifest();
const manifest = {
  ...sample,
  abiHash: ABI_HASH,
  markets: [{ ...sample.markets[0]!, marketId: BIG_ID, reserveId: "7" }, sample.markets[1]!],
  debtReserves: [{ ...sample.debtReserves[0]!, debtReserveId: "3", decimals: 18 }],
};

describe("loadManifest", () => {
  it("accepts a complete manifest whose ABI hash matches", () => {
    expect(loadManifest(write("ok.json", manifest), ABI_HASH).chainId).toBe(sample.chainId);
  });

  it("refuses a manifest built for other ABIs", () => {
    const path = write("other.json", { ...manifest, abiHash: `0x${"cd".repeat(32)}` });
    expect(() => loadManifest(path, ABI_HASH)).toThrow(/ABI hash/);
  });

  it("refuses a manifest that does not match the schema, naming every error", () => {
    const { roles: _roles, ...noRoles } = manifest;
    const bad = { ...noRoles, avana: { ...manifest.avana, accessManager: { ...manifest.avana.accessManager, startBlock: -1 } }, coverageSpokes: [] };
    const err = (() => {
      try {
        loadManifest(write("bad.json", bad), ABI_HASH);
      } catch (e) {
        return String(e);
      }
      return "";
    })();
    expect(err).toMatch(/does not match the release manifest schema/);
    expect(err).toMatch(/roles/);
    expect(err).toMatch(/avana\.accessManager\.startBlock/);
    expect(err).toMatch(/coverageSpokes/);
  });

  it("refuses an upper-case ABI hash through the schema", () => {
    const path = write("upper.json", { ...manifest, abiHash: ABI_HASH.toUpperCase().replace("0X", "0x") });
    expect(() => loadManifest(path, ABI_HASH)).toThrow(/abiHash/);
  });

  it("revives marketId, reserveId and debtReserveId as exact bigints", () => {
    const m = loadManifest(write("ids.json", manifest), ABI_HASH);
    expect(m.markets[0]?.marketId).toBe(18446744073709551617n);
    expect(m.markets[0]?.reserveId).toBe(7n);
    expect(m.debtReserves[0]?.debtReserveId).toBe(3n);
    // Only *Id fields named in the schema are revived; other numbers stay numbers.
    expect(m.markets[0]?.integrationId).toBe(1);
    expect(m.debtReserves[0]?.decimals).toBe(18);
  });

  it("refuses an ID that is not a decimal string", () => {
    const path = write("hex.json", { ...manifest, markets: [{ ...manifest.markets[0], marketId: "0x10" }] });
    expect(() => loadManifest(path, ABI_HASH)).toThrow(/marketId/);
  });
});

describe("aaveTopology", () => {
  const up = (n: number, startBlock = 10) => ({ address: `0x${n.toString(16).padStart(40, "0")}`, codeHash: `0x${"00".repeat(32)}`, implementation: `0x${"11".repeat(20)}`, startBlock });
  const aave = {
    hub: up(1),
    hubs: [{ ...up(1), label: "Stable LP", tier: 1 }, { ...up(2), label: "Core", tier: 2 }, { ...up(3, 20), label: "Growth", tier: 3 }],
    borrowSpokes: [{ ...up(0x11), label: "Stable LP Uniswap v3" }, { ...up(0x12), label: "Core Slipstream" }],
    lendSpoke: up(0x21),
    lendSpokes: [{ ...up(0x21), label: "Stable LP" }, { ...up(0x22), label: "Core" }, { ...up(0x23), label: "Growth" }],
    v3Pool: up(0x31),
  };

  it("reads every Hub, Lend Spoke and Borrow Spoke of a manifest with three Hubs", () => {
    const full = (x: ReturnType<typeof up>) => ({ ...x, implementationCodeHash: x.codeHash });
    const schemaAave = {
      hubs: aave.hubs.map((h) => ({ ...full(h), label: h.label, tier: h.tier })),
      borrowSpokes: aave.borrowSpokes.map((x) => ({ ...full(x), label: x.label })),
      lendSpokes: aave.lendSpokes.map((x) => ({ ...full(x), label: x.label })),
      v3Pool: full(aave.v3Pool),
      accessManager: manifest.aave.accessManager,
    };
    const m = loadManifest(write("hubs.json", { ...manifest, aave: schemaAave }), ABI_HASH);
    const t = aaveTopology(m);
    expect(t.hubs.map((h) => [h.label, h.tier, h.startBlock])).toEqual([["Stable LP", 1, 10], ["Core", 2, 10], ["Growth", 3, 20]]);
    expect(t.lendSpokes.map((s) => s.label)).toEqual(["Stable LP", "Core", "Growth"]);
    expect(t.borrowSpokes).toHaveLength(2);
  });

  it("refuses a manifest without a Hub or without a Lend Spoke", () => {
    expect(() => aaveTopology({ chainId: 1, aave: { ...aave, hubs: [] } } as never)).toThrow(/no Hub/);
    expect(() => aaveTopology({ chainId: 1, aave: { ...aave, lendSpokes: [] } } as never)).toThrow(/no Lend Spoke/);
  });

  it("refuses a manifest naming one address twice", () => {
    const twice = { ...aave, lendSpokes: [...aave.lendSpokes, { ...up(2), label: "Hub B again" }] };
    expect(() => aaveTopology({ chainId: 1, aave: twice } as never)).toThrow(/twice/);
  });
});

describe("uniswapV4PoolManager", () => {
  it("is null for a manifest without a PoolManager", () => {
    expect(uniswapV4PoolManager(loadManifest(write("no-v4.json", manifest), ABI_HASH))).toBeNull();
  });

  it("reads the PoolManager address in lower case with its start block", () => {
    const pm = { address: "0x000000000004444C5dC75cB358380D2e3dE08A90", startBlock: 21_688_329 };
    expect(uniswapV4PoolManager({ uniswapV4: { poolManager: pm } } as never)).toEqual({ address: "0x000000000004444c5dc75cb358380d2e3de08a90", startBlock: 21_688_329 });
  });
});

describe("chainDeploymentOf", () => {
  it("gives the snapshot reader the manifest's Hubs, Spokes, loss layers, RiskModules, both markets of a pool and the debt reserves", () => {
    const m = loadManifest(write("deployment.json", manifest), ABI_HASH);
    const d = chainDeploymentOf(m);
    const rm = sample.avana.integrations[0]!.riskModule.address.toLowerCase();
    expect(d.riskModules).toEqual([rm]);
    expect(d.markets.map((x) => [x.marketId, x.kind, x.riskModule, x.reserveId])).toEqual([
      [18446744073709551617n, "full-range", rm, 7n],
      [2n, "custom-range", rm, 32n],
    ]);
    expect(d.cdpSpokes).toEqual([{ address: sample.aave.borrowSpokes[0]!.address.toLowerCase(), hub: sample.aave.hubs[0]!.address.toLowerCase() }]);
    expect(d.firstLossReserves.map((f) => f.address)).toEqual([sample.coverage.firstLossReserves[0]!.address.toLowerCase()]);
    expect(d.deficitOffsets).toHaveLength(1);
    expect(d.debtReserves).toEqual([{ spoke: sample.debtReserves[0]!.spoke.toLowerCase(), reserveId: 3n, fixedPrice: false }]);
  });
});
