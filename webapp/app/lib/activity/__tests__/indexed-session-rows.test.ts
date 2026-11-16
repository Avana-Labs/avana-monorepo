import { describe, expect, it } from "vitest"
import { withoutIndexedSessionRows } from "../indexed-session-rows"
import { mergeTransactionRows, type DetailTransactionRow } from "@/app/lib/detail-page/transaction-history"

const HASH = `0x${"ab".repeat(32)}`
const OTHER = `0x${"cd".repeat(32)}`

describe("withoutIndexedSessionRows", () => {
  it("drops a session row only when an indexed row has its hash and its kind", () => {
    const session = [
      { id: "pledge", txHash: HASH, kind: "pledge" },
      { id: "borrow", txHash: HASH, kind: "borrow" },
      { id: "other", txHash: OTHER, kind: "pledge" },
      { id: "pending", txHash: "", kind: "pledge" },
      { id: "local", txHash: "0xlocal", kind: "pledge" },
    ]
    // One batch: the pledge is indexed, its borrow not yet.
    const kept = withoutIndexedSessionRows(session, [
      { txHash: HASH.toUpperCase().replace("0X", "0x"), kind: "pledge" },
    ])
    expect(kept.map((r) => r.id)).toEqual(["borrow", "other", "pending", "local"])
  })

  it("matches an indexed reduced collateral to the session's withdrawal", () => {
    const kept = withoutIndexedSessionRows([{ txHash: HASH, kind: "withdraw" }], [{ txHash: HASH, kind: "reduce" }])
    expect(kept).toEqual([])
  })
})

describe("mergeTransactionRows", () => {
  const row = (id: string, kind: string, txHash?: string): DetailTransactionRow => ({
    id,
    at: "2026-11-16T12:00:00.000Z",
    kind,
    amountLabel: "$1",
    txHashShort: (txHash ?? id).slice(0, 10),
    txHash,
  })

  it("shows an indexed transaction once, and keeps the session's rows the index does not cover", () => {
    const merged = mergeTransactionRows(
      [row("s1", "supply", HASH), row("s2", "borrow", HASH)],
      [row("31337:1:0", "supply", HASH)],
    )
    expect(merged.map((r) => r.id)).toEqual(["s2", "31337:1:0"])
  })
})
