// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Transaction progress states (lib/intents.ts): included and failed from the receipt, back to pending on a reorg,
// indexed from the export, confirmed after finality when the export never carries the transaction, dropped when
// no receipt arrives.

import { describe, expect, it } from "vitest";
import { DROP_AFTER_MS, EXPORT_GRACE_MS, type IntentState, type Observation, isFinal, nextIntentState } from "../convex/lib/intents.ts";

const T0 = 1_767_225_600_000;
const H = (n: number) => `0x${n.toString(16).padStart(64, "0")}`;
const obs = (o: Partial<Observation> = {}): Observation => ({ receipt: null, canonicalHash: null, indexed: false, finalizedBlock: null, now: T0 + 1_000, ...o });
const pending: IntentState = { status: "pending", submittedAt: T0 };
const included: IntentState = { status: "included", submittedAt: T0, blockNumber: "100", blockHash: H(100) };

describe("intent states", () => {
  it("moves pending to included or failed from the receipt", () => {
    expect(nextIntentState(pending, obs({ receipt: { success: true, blockNumber: "100", blockHash: H(100) } }))).toEqual(included);
    expect(nextIntentState(pending, obs({ receipt: { success: false, blockNumber: "100", blockHash: H(100) } })).status).toBe("failed");
  });

  it("keeps a pending intent without receipt, then drops it", () => {
    expect(nextIntentState(pending, obs())).toBe(pending);
    expect(nextIntentState(pending, obs({ now: T0 + DROP_AFTER_MS + 1 })).status).toBe("dropped");
  });

  it("returns an included intent to pending when its block is reorged, and follows a re-inclusion", () => {
    expect(nextIntentState(included, obs({ canonicalHash: H(999) }))).toEqual(pending);
    const moved = nextIntentState(included, obs({ canonicalHash: H(100), receipt: { success: true, blockNumber: "101", blockHash: H(101) } }));
    expect(moved).toMatchObject({ status: "included", blockNumber: "101", blockHash: H(101) });
  });

  it("settles on the export, even before the receipt is seen", () => {
    expect(nextIntentState(included, obs({ indexed: true }))).toMatchObject({ status: "indexed", blockNumber: "100" });
    expect(nextIntentState(pending, obs({ indexed: true })).status).toBe("indexed");
  });

  it("confirms an included intent the export never carries, once finalized and after the grace period", () => {
    const seen = nextIntentState(included, obs({ canonicalHash: H(100), finalizedBlock: "100" }));
    expect(seen).toMatchObject({ status: "included", finalizedAt: T0 + 1_000 });
    expect(nextIntentState(seen, obs({ canonicalHash: H(100), finalizedBlock: "100", now: T0 + 1_000 + EXPORT_GRACE_MS }))).toBe(seen);
    expect(nextIntentState(seen, obs({ canonicalHash: H(100), finalizedBlock: "100", now: T0 + 2_000 + EXPORT_GRACE_MS })).status).toBe("confirmed");
    expect(nextIntentState(included, obs({ canonicalHash: H(100), finalizedBlock: "99" }))).toBe(included);
  });

  it("treats finalized failures and the settled states as final", () => {
    const failed: IntentState = { status: "failed", submittedAt: T0, blockNumber: "100", blockHash: H(100) };
    const final = nextIntentState(failed, obs({ canonicalHash: H(100), finalizedBlock: "120" }));
    expect(isFinal(final.status, final.finalizedAt)).toBe(true);
    expect(nextIntentState(final, obs({ canonicalHash: H(1) }))).toBe(final);
    expect(isFinal("failed")).toBe(false);
    for (const s of ["indexed", "confirmed", "dropped"] as const) expect(isFinal(s)).toBe(true);
  });
});
