// loadManifest: a service refuses a manifest that does not match the release manifest schema or was built for other
// ABIs, and uint256 IDs stored as decimal strings come back as bigint without loss above 2^53. aaveTopology: the Hubs
// and Spokes of a manifest with several Hubs, in the shape packages/protocol writes (labelled Hubs with a tier,
// labelled Lend and Borrow Spokes).

import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { sampleManifest } from "@avana/protocol/manifest/sample";
import { aaveTopology, loadManifest } from "../src/manifest.ts";

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
const lpOracle = { ...sample.aave.v3Pool, logics: [] };
const manifest = {
  ...sample,
  abiHash: ABI_HASH,
  markets: [
    {
      marketId: BIG_ID,
      integrationId: 1,
      spoke: sample.aave.borrowSpokes[0]!.address,
      vaultToken: sample.avana.lock,
      lpOracle,
      reserveId: "7",
      pool: sample.external[0]!.address,
      tokens: [sample.external[0]!.address],
      feeds: [],
      routes: [],
    },
  ],
  debtReserves: [{ spoke: sample.aave.borrowSpokes[0]!.address, debtReserveId: "3", asset: sample.external[0]!.address, decimals: 18, isGho: false, debtOracle: null, feeds: [] }],
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
    const bad = { ...noRoles, avana: { ...manifest.avana, lens: { ...manifest.avana.lens, startBlock: -1 } }, coverageSpokes: [] };
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
    expect(err).toMatch(/avana\.lens\.startBlock/);
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
    const full = (x: ReturnType<typeof up>) => ({ ...x, implementationCodeHash: x.codeHash, implementationArtifact: "Hub.sol:Hub", logics: [] });
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
