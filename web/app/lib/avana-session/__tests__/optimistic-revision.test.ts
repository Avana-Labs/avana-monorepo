import { describe, expect, it } from "vitest"
import {
  advanceRevisionOnSuccess,
  captureHydratedRevisions,
  positionRevisionKey,
  seedRevisionFromReceipt,
  withExpectedRevision,
} from "@/app/lib/avana-session/optimistic-revision"

describe("optimistic-revision tracking", () => {
  it("keys by product:market and ignores positions with no market", () => {
    expect(positionRevisionKey("borrow", "uni-v3")).toBe("borrow:uni-v3")
    expect(positionRevisionKey("lend", undefined)).toBeNull()
    expect(positionRevisionKey("lend", null)).toBeNull()
  })

  it("captures hydrated revisions and clears stale entries on re-hydration", () => {
    const map = new Map<string, number>()
    captureHydratedRevisions(map, [
      { product: "lend", marketSlug: "usdc", revision: 3 },
      { product: "borrow", marketSlug: "uni-v3", revision: 0 },
      { product: "multiply", marketSlug: undefined, revision: 9 }, // no market → skipped
    ])
    expect(map.get("lend:usdc")).toBe(3)
    expect(map.get("borrow:uni-v3")).toBe(0)
    expect(map.size).toBe(2)

    // A later hydration where the borrow position closed drops it from the map.
    captureHydratedRevisions(map, [{ product: "lend", marketSlug: "usdc", revision: 4 }])
    expect(map.get("lend:usdc")).toBe(4)
    expect(map.has("borrow:uni-v3")).toBe(false)
  })

  it("attaches expectedRevision only when the position revision is known", () => {
    const map = new Map<string, number>([["lend:usdc", 2]])
    const known = withExpectedRevision({ marketSlug: "usdc", position: { marketSlug: "usdc" } }, "lend", map)
    expect(known.key).toBe("lend:usdc")
    expect((known.args as { expectedRevision?: number }).expectedRevision).toBe(2)

    // Unknown position (never hydrated) → no expectedRevision, so the server treats it as a create.
    const unknown = withExpectedRevision({ marketSlug: "dai", position: { marketSlug: "dai" } }, "lend", map)
    expect(unknown.key).toBe("lend:dai")
    expect((unknown.args as { expectedRevision?: number }).expectedRevision).toBeUndefined()
  })

  it("advances revision on a successful non-idempotent write for same-tab sequential writes", () => {
    const map = new Map<string, number>()

    // First write creates the position → seed to 0.
    advanceRevisionOnSuccess(map, "lend:usdc", false)
    expect(map.get("lend:usdc")).toBe(0)

    // The next same-tab write echoes 0, succeeds, → advance to 1.
    const first = withExpectedRevision({ position: { marketSlug: "usdc" } }, "lend", map)
    expect((first.args as { expectedRevision?: number }).expectedRevision).toBe(0)
    advanceRevisionOnSuccess(map, first.key, false)
    expect(map.get("lend:usdc")).toBe(1)

    // Idempotent replay must NOT advance (server revision unchanged).
    advanceRevisionOnSuccess(map, "lend:usdc", true)
    expect(map.get("lend:usdc")).toBe(1)
  })

  it("seeds the map from the receipt revision, including an idempotent replay (regression: M-12)", () => {
    const map = new Map<string, number>()
    // An idempotent CREATE replay: map is empty and the +1 inference would skip it, leaving
    // the next write with no expectedRevision → REVISION_REQUIRED. Seeding from the receipt
    // (server-authoritative revision 0) fixes it.
    seedRevisionFromReceipt(map, "borrow:uni-v3", 0)
    expect(map.get("borrow:uni-v3")).toBe(0)
    const next = withExpectedRevision({ position: { marketSlug: "uni-v3" } }, "borrow", map)
    expect((next.args as { expectedRevision?: number }).expectedRevision).toBe(0)

    // A later write reports revision 1; the map tracks the server value exactly.
    seedRevisionFromReceipt(map, "borrow:uni-v3", 1)
    expect(map.get("borrow:uni-v3")).toBe(1)

    // No key or no revision → no-op.
    seedRevisionFromReceipt(map, null, 5)
    seedRevisionFromReceipt(map, "borrow:uni-v3", null)
    expect(map.get("borrow:uni-v3")).toBe(1)
  })
})
