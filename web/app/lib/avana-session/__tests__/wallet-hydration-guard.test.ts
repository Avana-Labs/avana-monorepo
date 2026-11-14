import { describe, expect, it } from "vitest"
import { HYDRATION_GATE_TTL_MS, pendingHydrationIntentIds, shouldApplyHydration } from "../wallet-hydration-guard"

const snap = (intentIds: Array<string | undefined | null>) => ({
  transactions: intentIds.map((intentId) => ({ intentId })),
})

describe("shouldApplyHydration (WalletHydrator in-flight guard, H19)", () => {
  it("does not apply while the query is still loading (undefined)", () => {
    expect(shouldApplyHydration(undefined, [])).toBe(false)
  })

  it("applies a snapshot when the client has no local intents", () => {
    expect(shouldApplyHydration(snap(["a", "b"]), [])).toBe(true)
  })

  it("applies when every local intent is reflected in the snapshot", () => {
    expect(shouldApplyHydration(snap(["a", "b", "c"]), ["a", "b"])).toBe(true)
  })

  it("SKIPS a stale re-emit that is missing an in-flight optimistic intent", () => {
    // The user just submitted "c" (optimistic, local) but this emit predates its write —
    // applying it would clobber the in-flight edit.
    expect(shouldApplyHydration(snap(["a", "b"]), ["a", "b", "c"])).toBe(false)
  })

  it("applies once the write lands and the emit finally contains the intent", () => {
    expect(shouldApplyHydration(snap(["a", "b", "c"]), ["a", "b", "c"])).toBe(true)
  })

  it("ignores snapshot rows with no intentId when matching", () => {
    // A seed/legacy row without an intentId can't satisfy a pending local intent.
    expect(shouldApplyHydration(snap([undefined, "a"]), ["a"])).toBe(true)
    expect(shouldApplyHydration(snap([undefined]), ["a"])).toBe(false)
  })
})

describe("pendingHydrationIntentIds (freeze guard, C-3)", () => {
  const now = 1_000_000
  const item = (intentId: string, status: string, ageMs: number) => ({
    intentId,
    status,
    timestamp: now - ageMs,
  })

  it("gates on recent success/pending intents", () => {
    const pending = pendingHydrationIntentIds([item("a", "success", 100), item("b", "pending", 100)], now)
    expect([...pending].sort()).toEqual(["a", "b"])
  })

  it("NEVER gates on a failed intent — a rejected write must not freeze hydration", () => {
    // The core C-3 fix: a failed action's intent id was never (durably) persisted, so a stale
    // re-emit that omits it must still be applied rather than skipped forever.
    const pending = pendingHydrationIntentIds([item("failed-1", "failed", 50)], now)
    expect(pending.size).toBe(0)
    expect(shouldApplyHydration(snap(["x"]), pending)).toBe(true)
  })

  it("expires an aged-out intent so a lost/never-landing write cannot freeze forever", () => {
    const stale = item("old", "success", HYDRATION_GATE_TTL_MS + 1)
    const fresh = item("new", "success", 10)
    const pending = pendingHydrationIntentIds([stale, fresh], now)
    expect([...pending]).toEqual(["new"])
    // A snapshot missing only the aged-out intent is now safe to apply.
    expect(shouldApplyHydration(snap(["new"]), pending)).toBe(true)
  })

  it("still protects a genuinely in-flight recent success edit", () => {
    const pending = pendingHydrationIntentIds([item("inflight", "success", 200)], now)
    expect(shouldApplyHydration(snap(["other"]), pending)).toBe(false)
  })
})
