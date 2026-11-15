// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Head order: a missed block delivered after the newer one that revealed it is skipped, not taken for a reorg; a
// block replaced at a height already processed is still a reorg.

import { describe, expect, it } from "vitest";
import { type Head, ProcessedHeads, isReorg } from "../src/discovery/stream.ts";

const hash = (n: bigint, fork = "a") => `0x${fork.repeat(2)}${n.toString(16).padStart(62, "0")}` as `0x${string}`;
const head = (n: bigint, fork = "a", parentFork = fork): Head => ({ number: n, hash: hash(n, fork), parentHash: hash(n - 1n, parentFork), timestamp: n * 12n });

/** The chain loop's decision for each delivered head, in order: skipped as late, processed, or processed as a reorg. */
function replay(delivered: readonly Head[]): string[] {
  const seen = new ProcessedHeads();
  let previous: Head | null = null;
  return delivered.map((h) => {
    if (seen.isLate(previous, h)) return `${h.number} late`;
    const reorg = isReorg(previous, h);
    previous = h;
    seen.record(h);
    return `${h.number} ${reorg ? "reorg" : "processed"}`;
  });
}

describe("ProcessedHeads", () => {
  it("skips a missed block delivered after the newer head, as the drill's subscription did at 7395 and 7400", () => {
    const order = [7394n, 7396n, 7395n, 7397n, 7398n, 7399n, 7401n, 7400n, 7402n].map((n) => head(n));
    expect(replay(order)).toEqual([
      "7394 processed",
      "7396 processed",
      "7395 late",
      "7397 processed",
      "7398 processed",
      "7399 processed",
      "7401 processed",
      "7400 late",
      "7402 processed",
    ]);
  });

  it("skips a head delivered twice", () => {
    expect(replay([head(10n), head(11n), head(11n)])).toEqual(["10 processed", "11 processed", "11 late"]);
  });

  it("still reports a reorg when a processed height comes back with another hash", () => {
    expect(replay([head(10n), head(11n), head(11n, "b", "a")])).toEqual(["10 processed", "11 processed", "11 reorg"]);
  });

  it("still reports a reorg when the next head's parent is not the processed head", () => {
    expect(replay([head(10n), head(11n), head(12n, "b", "b")])).toEqual(["10 processed", "11 processed", "12 reorg"]);
  });

  it("forgets heights more than 128 below the newest", () => {
    const seen = new ProcessedHeads();
    seen.record(head(10n));
    seen.record(head(200n));
    expect(seen.isLate(head(200n), head(10n))).toBe(false);
    expect(seen.isLate(head(200n), head(199n))).toBe(true);
  });
});
