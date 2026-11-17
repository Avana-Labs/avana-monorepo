// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Snapshot rows are written on change (ingest/apply.ts, needsWrite): a row whose values equal the stored row's is left
// alone, whatever its read block and time, until the stored read is UNCHANGED_REWRITE_MS old; any changed value, a
// field added or removed, or a changed nested value is written at once.

import { describe, expect, it } from "vitest";
import { UNCHANGED_REWRITE_MS, needsWrite } from "../convex/ingest/apply.ts";

const T = 1_767_225_600_000;
const stored = { _id: "x", _creationTime: 1, chainId: 1, hub: "0xa", owed: "100", caps: { tokenUsdCaps8: ["1", "2"] }, slug: "a", blockNumber: "10", timestamp: 5, updatedAt: T };
const fresh = (o: Record<string, unknown> = {}) => ({ chainId: 1, slug: "a", hub: "0xa", caps: { tokenUsdCaps8: ["1", "2"] }, owed: "100", blockNumber: "15", timestamp: 65, updatedAt: T + 60_000, ...o });

describe("snapshot writes", () => {
  it("skips a row whose values did not change, in any key order and at any later block", () => {
    expect(needsWrite(stored, fresh())).toBe(false);
  });

  it("writes a changed value, a changed nested value, and a field added or removed", () => {
    expect(needsWrite(stored, fresh({ owed: "101" }))).toBe(true);
    expect(needsWrite(stored, fresh({ caps: { tokenUsdCaps8: ["1", "3"] } }))).toBe(true);
    expect(needsWrite(stored, fresh({ label: "Stable" }))).toBe(true);
    const { slug: _s, ...withoutSlug } = fresh();
    expect(needsWrite(stored, withoutSlug)).toBe(true);
  });

  it("rewrites an unchanged row once its stored read is 10 minutes old", () => {
    expect(UNCHANGED_REWRITE_MS).toBe(600_000);
    expect(needsWrite(stored, fresh({ updatedAt: T + UNCHANGED_REWRITE_MS - 1 }))).toBe(false);
    expect(needsWrite(stored, fresh({ updatedAt: T + UNCHANGED_REWRITE_MS }))).toBe(true);
  });
});
