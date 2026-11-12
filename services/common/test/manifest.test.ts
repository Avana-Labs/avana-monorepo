// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// loadManifest: a service refuses a manifest built for other ABIs, and uint256 IDs stored as decimal strings come
// back as bigint without loss above 2^53.

import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { loadManifest } from "../src/manifest.ts";

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
