// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The snapshot rules at their boundaries, on the services-common fixture snapshot: M-01, M-06, M-08, M-15, M-18,
// M-19, M-24 and M-29.

import { describe, expect, it } from "vitest";
import { FIXTURE_HUB, FIXTURE_LEND, FIXTURE_U, FIXTURE_X, fixtureHubAsset, fixtureMarkets, fixtureSlices, fixtureSpokeReserves } from "@avana/services-common/fixtures";
import type { ChainSnapshot, HubAssetRow, MarketRow } from "@avana/services-common/views";
import { MAX_SPOKE_CAP } from "@avana/services-common/views";
import { BREAKER, SnapshotMemory, breakerNames, evaluateSnapshot, m18, m19Utilization } from "../src/rules/snapshot.ts";
import type { Finding } from "../src/types.ts";

const T0 = 1_767_225_600;

function snapshot(timestamp: number, edit: { markets?: (m: MarketRow) => MarketRow; asset?: (a: HubAssetRow) => HubAssetRow; lendAdded?: string; owedX?: string; hubState?: number } = {}): ChainSnapshot {
  return {
    chainId: 1,
    blockNumber: String(timestamp),
    timestamp,
    hubs: [{ chainId: 1, hub: FIXTURE_HUB, label: "Stable", tier: 1, recorded: true, applicationState: edit.hubState ?? 0, assetCount: 1, lendAssetIds: ["1"], lendSpokes: [FIXTURE_LEND], cdpSpokes: [FIXTURE_U, FIXTURE_X], blockNumber: String(timestamp) }],
    creditLines: [],
    hubAssets: [edit.asset ? edit.asset(fixtureHubAsset) : fixtureHubAsset],
    slices: fixtureSlices.map((s) => (s.spoke === FIXTURE_LEND && edit.lendAdded ? { ...s, added: edit.lendAdded } : s.spoke === FIXTURE_X && edit.owedX ? { ...s, owed: edit.owedX } : s)),
    spokeReserves: fixtureSpokeReserves,
    markets: fixtureMarkets.map((m) => (edit.markets ? edit.markets(m) : m)),
  };
}

const pick = (fs: readonly Finding[], signal: string, subject?: string) => fs.filter((f) => f.signal === signal && (subject === undefined || f.subject === subject));
const levelOf = (fs: readonly Finding[], signal: string, subject: string) => {
  const found = pick(fs, signal, subject);
  expect(found).toHaveLength(1);
  return found[0]!.level;
};

describe("evaluateSnapshot on a healthy fixture", () => {
  it("reports every condition ok and no event", () => {
    const fs = evaluateSnapshot(snapshot(T0), new SnapshotMemory());
    expect(fs.filter((f) => f.level !== "ok")).toEqual([]);
    expect(fs.filter((f) => f.kind === "event")).toEqual([]);
    // One M-01, M-06 and M-08 per market, one M-08 per debt reserve, M-15 and M-19 per Hub asset, M-18 per capped
    // CDP slice, one withdrawal check per Lend Spoke slice.
    expect(pick(fs, "M-01")).toHaveLength(2);
    expect(pick(fs, "M-06")).toHaveLength(2);
    expect(pick(fs, "M-08")).toHaveLength(4);
    expect(pick(fs, "M-15")).toHaveLength(1);
    expect(pick(fs, "M-18")).toHaveLength(2);
    expect(pick(fs, "M-19")).toHaveLength(2);
  });
});

describe("M-01 price state", () => {
  it("warns on Cached and pages on Expired; Drifting is ok", () => {
    const states = [1, 2, 3].map((priceState) => levelOf(evaluateSnapshot(snapshot(T0, { markets: (m) => ({ ...m, priceState }) }), new SnapshotMemory()), "M-01", "market:1"));
    expect(states).toEqual(["ok", "warn", "page"]);
  });
});

describe("M-06 collateral value", () => {
  const value = (m: MarketRow, bps: bigint) => ({ ...m, suppliedUsd8: ((BigInt(m.suppliedUsd8) * bps) / 10_000n).toString(10) });

  it("warns at a 10 % fall within the hour and pages at 25 %", () => {
    const mem = new SnapshotMemory();
    evaluateSnapshot(snapshot(T0), mem);
    expect(levelOf(evaluateSnapshot(snapshot(T0 + 600, { markets: (m) => value(m, 9_001n) }), mem), "M-06", "market:1")).toBe("ok");
    expect(levelOf(evaluateSnapshot(snapshot(T0 + 1_200, { markets: (m) => value(m, 9_000n) }), mem), "M-06", "market:1")).toBe("warn");
    expect(levelOf(evaluateSnapshot(snapshot(T0 + 1_800, { markets: (m) => value(m, 7_500n) }), mem), "M-06", "market:1")).toBe("page");
  });

  it("does not count a fall that took longer than the hour", () => {
    const mem = new SnapshotMemory();
    evaluateSnapshot(snapshot(T0), mem);
    evaluateSnapshot(snapshot(T0 + 1_800, { markets: (m) => value(m, 9_500n) }), mem);
    // At T0 + 3,599 the T0 peak is still inside the hour: −14 %.
    expect(levelOf(evaluateSnapshot(snapshot(T0 + 3_599, { markets: (m) => value(m, 8_600n) }), mem), "M-06", "market:1")).toBe("warn");
    // At T0 + 5,401 both earlier samples have left the hour: the value has not moved since T0 + 3,599.
    expect(levelOf(evaluateSnapshot(snapshot(T0 + 5_401, { markets: (m) => value(m, 8_600n) }), mem), "M-06", "market:1")).toBe("ok");
  });
});

describe("M-08 breakers", () => {
  it("warns on a temporary gate and pages on every security freeze", () => {
    const at = (reasons: number) => levelOf(evaluateSnapshot(snapshot(T0, { markets: (m) => ({ ...m, breakerReasons: reasons }) }), new SnapshotMemory()), "M-08", "market:1");
    expect(at(BREAKER.ORACLE)).toBe("warn");
    expect(at(BREAKER.POOL_SHARE | BREAKER.POOL_DEPTH)).toBe("warn");
    for (const freeze of [BREAKER.ISSUER, BREAKER.DEFICIT, BREAKER.MANUAL, BREAKER.CONFIG_DRIFT]) expect(at(freeze)).toBe("page");
  });

  it("names the reasons", () => {
    expect(breakerNames(BREAKER.ORACLE | BREAKER.MANUAL)).toBe("ORACLE|MANUAL");
    expect(breakerNames(0)).toBe("none");
  });
});

describe("M-15 Hub deficit", () => {
  const withDeficit = (uncovered: string) => (a: HubAssetRow): HubAssetRow => ({ ...a, deficit: "5000000", exposure: { ...a.exposure!, uncovered } });
  const subject = `hubAsset:${FIXTURE_HUB}:1`;

  it("warns on any deficit and pages once it stayed uncovered for 24 hours", () => {
    const mem = new SnapshotMemory();
    expect(levelOf(evaluateSnapshot(snapshot(T0, { asset: withDeficit("0") }), mem), "M-15", subject)).toBe("warn");
    expect(levelOf(evaluateSnapshot(snapshot(T0 + 60, { asset: withDeficit("1") }), mem), "M-15", subject)).toBe("warn");
    expect(levelOf(evaluateSnapshot(snapshot(T0 + 60 + 86_399, { asset: withDeficit("1") }), mem), "M-15", subject)).toBe("warn");
    expect(levelOf(evaluateSnapshot(snapshot(T0 + 60 + 86_400, { asset: withDeficit("1") }), mem), "M-15", subject)).toBe("page");
  });

  it("restarts the 24 hours when the deficit is covered in between", () => {
    const mem = new SnapshotMemory();
    evaluateSnapshot(snapshot(T0, { asset: withDeficit("1") }), mem);
    evaluateSnapshot(snapshot(T0 + 43_200, { asset: withDeficit("0") }), mem);
    evaluateSnapshot(snapshot(T0 + 43_260, { asset: withDeficit("1") }), mem);
    expect(levelOf(evaluateSnapshot(snapshot(T0 + 86_400, { asset: withDeficit("1") }), mem), "M-15", subject)).toBe("warn");
  });
});

describe("M-18 draw cap use", () => {
  it("warns at 80 % and pages at 90 % of the cap, in base units against whole tokens", () => {
    expect(m18(2_399_999_999_999n, 3_000_000n, 6)).toBe("ok");
    expect(m18(2_400_000_000_000n, 3_000_000n, 6)).toBe("warn");
    expect(m18(2_700_000_000_000n, 3_000_000n, 6)).toBe("page");
  });

  it("skips an unlimited or zero cap", () => {
    expect(m18(1n, MAX_SPOKE_CAP, 6)).toBeNull();
    expect(m18(1n, 0n, 6)).toBeNull();
  });

  it("reads the CDP slice of the snapshot", () => {
    const fs = evaluateSnapshot(snapshot(T0, { owedX: "2700000000000" }), new SnapshotMemory());
    expect(levelOf(fs, "M-18", `slice:${FIXTURE_HUB}:1:${FIXTURE_X}`)).toBe("page");
  });
});

describe("M-19 utilization and withdrawals", () => {
  it("warns at 90 % utilization and pages at 98 %", () => {
    expect([8_999, 9_000, 9_799, 9_800].map(m19Utilization)).toEqual(["ok", "warn", "warn", "page"]);
  });

  it("pages when a Lend Spoke's supply falls more than 10 % within the hour", () => {
    const mem = new SnapshotMemory();
    const subject = `slice:${FIXTURE_HUB}:1:${FIXTURE_LEND}:withdrawals`;
    evaluateSnapshot(snapshot(T0), mem);
    expect(levelOf(evaluateSnapshot(snapshot(T0 + 600, { lendAdded: "8820000000000" }), mem), "M-19", subject)).toBe("ok"); // −10 % exactly
    expect(levelOf(evaluateSnapshot(snapshot(T0 + 1_200, { lendAdded: "8819000000000" }), mem), "M-19", subject)).toBe("page");
  });
});

describe("M-24 and M-29 changes", () => {
  it("reports a pause change, a manual trip and a Hub state change once, as events", () => {
    const mem = new SnapshotMemory();
    evaluateSnapshot(snapshot(T0), mem);
    const fs = evaluateSnapshot(snapshot(T0 + 12, { markets: (m) => (m.marketId === "1" ? { ...m, pauseState: 2, breakerReasons: BREAKER.MANUAL } : m), hubState: 1 }), mem);
    const events = pick(fs, "M-24");
    expect(events.map((e) => [e.subject, e.kind, e.level])).toEqual([
      ["market:1", "event", "warn"],
      ["market:1", "event", "warn"],
      [`hub:${FIXTURE_HUB}`, "event", "warn"],
    ]);
    expect(events[0]!.detail.pauseState).toBe("None -> Paused");
    expect(events[2]!.detail.applicationState).toBe("None -> Frozen");
    // The same state on the next snapshot is not reported again.
    expect(pick(evaluateSnapshot(snapshot(T0 + 24, { markets: (m) => (m.marketId === "1" ? { ...m, pauseState: 2, breakerReasons: BREAKER.MANUAL } : m), hubState: 1 }), mem), "M-24")).toEqual([]);
  });

  it("reports a rate-curve change", () => {
    const mem = new SnapshotMemory();
    evaluateSnapshot(snapshot(T0), mem);
    const fs = evaluateSnapshot(snapshot(T0 + 12, { asset: (a) => ({ ...a, rateCurve: { ...a.rateCurve!, baseDrawnRateBps: 50 } }) }), mem);
    const [change] = pick(fs, "M-29");
    expect(change?.kind).toBe("event");
    expect(change?.detail.after).toContain('"baseDrawnRateBps":50');
  });
});
