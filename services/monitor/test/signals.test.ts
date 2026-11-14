// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The catalog matches services/README.md (one row per signal, M-01 to M-29, each with a responder and a playbook),
// and the level helpers treat the limits exactly.

import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { History } from "../src/history.ts";
import { SIGNALS, maxLevel, ratioLevel, signal, thresholdLevel } from "../src/signals.ts";

const README = readFileSync(new URL("../../README.md", import.meta.url), "utf8");

describe("signal catalog", () => {
  it("lists M-01 to M-29 once each, in order", () => {
    expect(SIGNALS.map((s) => s.id)).toEqual(Array.from({ length: 29 }, (_, i) => `M-${String(i + 1).padStart(2, "0")}`));
  });

  it("has every signal of the services README table and names its playbook", () => {
    const rows = [...README.matchAll(/^\| (M-\d\d) \|.*\| ([^|]+) \|$/gm)].map((m) => [m[1], m[2]!.trim()]);
    expect(rows.map((r) => r[0])).toEqual(SIGNALS.map((s) => s.id));
    for (const [id, playbook] of rows) expect(playbook).toContain(signal(id as `M-${string}`).playbook.split(" ")[0]);
  });

  it("names at least one responder for every signal", () => {
    for (const s of SIGNALS) expect(s.responders.length).toBeGreaterThan(0);
  });

  it("refuses an unknown signal", () => {
    expect(() => signal("M-99")).toThrow(/unknown signal/);
  });
});

describe("levels", () => {
  it("thresholdLevel does not count a value at the limit", () => {
    expect(thresholdLevel(0.95, 0.95, 0.9, "below")).toBe("ok");
    expect(thresholdLevel(0.9499, 0.95, 0.9, "below")).toBe("warn");
    expect(thresholdLevel(0.8999, 0.95, 0.9, "below")).toBe("page");
    expect(thresholdLevel(0.2001, 0.15, 0.2, "above")).toBe("page");
  });

  it("ratioLevel is exact in integers and counts the limit with atOrAbove", () => {
    expect(ratioLevel(80n, 100n, [80n, 100n], [90n, 100n], "atOrAbove")).toBe("warn");
    expect(ratioLevel(79_999_999n, 100_000_000n, [80n, 100n], [90n, 100n], "atOrAbove")).toBe("ok");
    expect(ratioLevel(90n, 100n, [80n, 100n], [90n, 100n], "atOrAbove")).toBe("page");
    expect(ratioLevel(90n, 100n, [80n, 100n], [90n, 100n], "above")).toBe("warn");
    expect(ratioLevel(149n, 100n, [150n, 100n], [100n, 100n], "below")).toBe("warn");
    expect(() => ratioLevel(1n, 0n, [1n, 1n], [1n, 1n], "above")).toThrow(/positive/);
  });

  it("maxLevel keeps the worse level", () => {
    expect(maxLevel("ok", "warn")).toBe("warn");
    expect(maxLevel("page", "warn")).toBe("page");
    expect(maxLevel("ok", "ok")).toBe("ok");
  });
});

describe("History", () => {
  it("measures a fall from the peak inside the window and forgets older samples", () => {
    const h = new History(3_600);
    h.record("v", 0, 1_000n);
    h.record("v", 1_800, 950n);
    h.record("v", 3_000, 800n);
    expect(h.dropBps("v")).toBe(2_000n);
    h.record("v", 3_700, 800n); // the 1,000 sample at t = 0 left the window; the peak is now 950
    expect(h.dropBps("v")).toBe(1_578n);
  });

  it("reports no fall for a rising value, an unknown key or a zero peak", () => {
    const h = new History(60);
    h.record("up", 0, 1n);
    h.record("up", 1, 2n);
    h.record("zero", 0, 0n);
    expect(h.dropBps("up")).toBe(0n);
    expect(h.dropBps("zero")).toBe(0n);
    expect(h.dropBps("missing")).toBe(0n);
  });

  it("refuses a sample older than the last and drops keys not retained", () => {
    const h = new History(60);
    h.record("a", 10, 1n);
    expect(() => h.record("a", 9, 1n)).toThrow(/older/);
    h.retain(new Set());
    expect(h.peak("a")).toBeNull();
  });
});
