// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// loadManifest: a service refuses a manifest built for other ABIs, and uint256 IDs stored as decimal strings come
// back as bigint without loss above 2^53. aaveTopology: the Hubs and Spokes of a manifest with several Hubs, in the
// shape packages/protocol writes (labelled Hubs with a tier, labelled Lend and Borrow Spokes).

import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
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

const manifest = {
  chainId: 1,
  release: "v1.0.0",
  abiHash: ABI_HASH,
  markets: [{ marketId: BIG_ID, reserveId: "7", integrationId: 1 }],
  debtReserves: [{ debtReserveId: "3", decimals: 18 }],
};

describe("loadManifest", () => {
  it("accepts a manifest whose ABI hash matches, in any letter case", () => {
    const path = write("ok.json", { ...manifest, abiHash: ABI_HASH.toUpperCase().replace("0X", "0x") });
    expect(loadManifest(path, ABI_HASH).chainId).toBe(1);
  });

  it("refuses a manifest built for other ABIs", () => {
    const path = write("other.json", { ...manifest, abiHash: `0x${"cd".repeat(32)}` });
    expect(() => loadManifest(path, ABI_HASH)).toThrow(/ABI hash/);
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
    const path = write("hex.json", { ...manifest, markets: [{ marketId: "0x10", reserveId: "1" }] });
    expect(() => loadManifest(path, ABI_HASH)).toThrow(/marketId is not a decimal string/);
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
    const m = loadManifest(write("hubs.json", { ...manifest, aave }), ABI_HASH);
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
