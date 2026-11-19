// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// M-30, the discovery mismatch: an account only one source holds (indexer stream or RPC log backfill), up to the
// block both have read, warns at once and pages after KEEPER_DISCOVERY_MISMATCH_PAGE_SECONDS; the alert stops once
// the sources agree. The keeper's signal table matches services/README.md, M-30 included.

import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import type { Address } from "viem";
import { CHAINS } from "@avana/services-common";
import { discoveryPageSeconds } from "../src/config.ts";
import { AccountCache } from "../src/discovery/accountCache.ts";
import { ACCOUNTS_IN_DETAIL, DISCOVERY_PAGE_SECONDS, DiscoveryWatch, discoveryThrough, m30Level } from "../src/monitoring/discovery.ts";
import { SIGNALS } from "../src/monitoring/signals.ts";

const addr = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as Address;
const SPOKE = addr(0x5b);

function account(cache: AccountCache, n: number, source: "indexer" | "rpc", createdBlock = 10n, chainId = 1) {
  return cache.upsert({ chainId, spoke: SPOKE, proxy: addr(0x1000 + n), wallet: addr(0x2000 + n), marketId: 1n, vaultToken: addr(0x77), createdBlock }, source);
}

describe("discoveryThrough", () => {
  it("is the lower of the two sources' blocks, negative while either has not answered", () => {
    expect(discoveryThrough(100n, 90n)).toBe(90n);
    expect(discoveryThrough(80n, 90n)).toBe(80n);
    expect(discoveryThrough(100n, -1n)).toBe(-1n);
  });
});

describe("m30Level", () => {
  it("warns at once and pages from pageBlocks on", () => {
    expect(m30Level(100n, 100n, 300n)).toBe("warn");
    expect(m30Level(100n, 399n, 300n)).toBe("warn");
    expect(m30Level(100n, 400n, 300n)).toBe("page");
  });
});

describe("DiscoveryWatch", () => {
  it("pages after one hour of blocks by default: 300 on Ethereum, 1,800 on Base", () => {
    expect(new DiscoveryWatch(CHAINS.mainnet).pageBlocks).toBe(300n);
    expect(new DiscoveryWatch(CHAINS.base).pageBlocks).toBe(1_800n);
    expect(new DiscoveryWatch(CHAINS.mainnet, 120).pageBlocks).toBe(10n);
  });

  it("sends nothing while the sources agree", () => {
    const cache = new AccountCache();
    account(cache, 1, "indexer");
    account(cache, 1, "rpc");
    const r = new DiscoveryWatch(CHAINS.mainnet).check(cache.oneSided(1, 100n), 100n, 100n);
    expect(r).toEqual({ indexerOnly: 0, rpcOnly: 0, alert: null });
  });

  it("does not count an account created after the block both sources have read", () => {
    const cache = new AccountCache();
    account(cache, 1, "rpc", 150n);
    expect(cache.oneSided(1, 100n)).toEqual([]);
    expect(new DiscoveryWatch(CHAINS.mainnet).check(cache.oneSided(1, 100n), 160n, 100n).alert).toBeNull();
  });

  it("warns on any one-sided account, counts each side and names the accounts", () => {
    const cache = new AccountCache();
    account(cache, 1, "indexer");
    account(cache, 2, "rpc");
    account(cache, 3, "rpc");
    account(cache, 4, "indexer");
    account(cache, 4, "rpc");
    const r = new DiscoveryWatch(CHAINS.mainnet).check(cache.oneSided(1, 100n), 120n, 100n);
    expect(r.indexerOnly).toBe(1);
    expect(r.rpcOnly).toBe(2);
    expect(r.alert).toMatchObject({ signal: "M-30", level: "warn", chainId: 1, blockNumber: 120n, subject: "discovery" });
    expect(r.alert!.detail).toMatchObject({ indexerOnly: "1", rpcOnly: "2", through: "100", oldestSince: "120", pageAfterBlocks: "300", playbook: "P-08" });
    expect(r.alert!.detail.accounts!.split(",").sort()).toEqual(
      [`${SPOKE}:${addr(0x1001)}:indexer`, `${SPOKE}:${addr(0x1002)}:rpc`, `${SPOKE}:${addr(0x1003)}:rpc`].sort(),
    );
  });

  it("pages once an account has stayed one-sided for the configured time, then resolves when the sources agree", () => {
    const cache = new AccountCache();
    const watch = new DiscoveryWatch(CHAINS.mainnet, 3_600);
    account(cache, 1, "rpc");
    expect(watch.check(cache.oneSided(1, 100n), 1_000n, 100n).alert?.level).toBe("warn");
    expect(watch.check(cache.oneSided(1, 100n), 1_299n, 100n).alert?.level).toBe("warn");
    // A second account joining later does not reset the first one's clock.
    account(cache, 2, "indexer");
    const paged = watch.check(cache.oneSided(1, 100n), 1_300n, 100n);
    expect(paged.alert).toMatchObject({ level: "page", detail: { oldestSince: "1000", indexerOnly: "1", rpcOnly: "1" } });
    // The oldest account is named first.
    expect(paged.alert!.detail.accounts!.split(",")[0]).toBe(`${SPOKE}:${addr(0x1001)}:rpc`);

    account(cache, 1, "indexer");
    account(cache, 2, "rpc");
    expect(watch.check(cache.oneSided(1, 100n), 1_301n, 100n)).toEqual({ indexerOnly: 0, rpcOnly: 0, alert: null });
  });

  it("starts a new episode when an account turns one-sided again", () => {
    const watch = new DiscoveryWatch(CHAINS.base, 60); // 30 Base blocks
    const cache = new AccountCache();
    const a = account(cache, 1, "rpc", 10n, CHAINS.base.id);
    expect(watch.check([a], 100n, 50n).alert?.level).toBe("warn");
    expect(watch.check([], 120n, 50n).alert).toBeNull();
    expect(watch.check([a], 140n, 50n).alert?.level).toBe("warn");
    expect(watch.check([a], 169n, 50n).alert?.level).toBe("warn");
    expect(watch.check([a], 170n, 50n).alert?.level).toBe("page");
  });

  it("names at most ACCOUNTS_IN_DETAIL accounts and keeps the detail within the monitor's 1,000 characters", () => {
    const cache = new AccountCache();
    for (let i = 0; i < 50; i++) account(cache, i, i % 2 === 0 ? "indexer" : "rpc");
    const r = new DiscoveryWatch(CHAINS.mainnet).check(cache.oneSided(1, 100n), 100n, 100n);
    expect(r.indexerOnly + r.rpcOnly).toBe(50);
    expect(r.alert!.detail.accounts!.split(",")).toHaveLength(ACCOUNTS_IN_DETAIL);
    for (const [k, v] of Object.entries(r.alert!.detail)) {
      expect(k.length).toBeLessThanOrEqual(64);
      expect(v.length).toBeLessThanOrEqual(1_000);
    }
  });
});

describe("KEEPER_DISCOVERY_MISMATCH_PAGE_SECONDS", () => {
  it("defaults to one hour and accepts a positive whole number of seconds", () => {
    expect(discoveryPageSeconds({})).toBe(DISCOVERY_PAGE_SECONDS);
    expect(discoveryPageSeconds({ KEEPER_DISCOVERY_MISMATCH_PAGE_SECONDS: " " })).toBe(3_600);
    expect(discoveryPageSeconds({ KEEPER_DISCOVERY_MISMATCH_PAGE_SECONDS: "900" })).toBe(900);
  });

  it("refuses zero, a fraction or a non-number", () => {
    for (const v of ["0", "1.5", "-60", "1h"]) expect(() => discoveryPageSeconds({ KEEPER_DISCOVERY_MISMATCH_PAGE_SECONDS: v })).toThrow(/positive integer/);
  });
});

describe("keeper signal table", () => {
  const README = readFileSync(new URL("../../README.md", import.meta.url), "utf8");

  it("lists M-01 to M-34 once each, in order, as the services README table does", () => {
    const ids = Array.from({ length: 34 }, (_, i) => `M-${String(i + 1).padStart(2, "0")}`);
    expect(SIGNALS.map((s) => s.id)).toEqual(ids);
    expect([...README.matchAll(/^\| (M-\d\d) \|/gm)].map((m) => m[1])).toEqual(ids);
  });

  it("names each signal's playbook as the README row does", () => {
    for (const m of README.matchAll(/^\| (M-\d\d) \|.*\| ([^|]+) \|$/gm)) {
      const def = SIGNALS.find((s) => s.id === m[1])!;
      expect(m[2]).toContain(def.playbook.split(" ")[0]);
    }
  });

  it("states M-11 against routeDepthThreshold in base units of the debt asset", () => {
    const m11 = SIGNALS.find((s) => s.id === "M-11")!;
    expect(m11.inputs.join(" ")).toContain("routeDepthThreshold(marketId, token, debtAsset, kind)");
    expect(m11.inputs.join(" ")).not.toMatch(/Gho\b/);
  });
});
