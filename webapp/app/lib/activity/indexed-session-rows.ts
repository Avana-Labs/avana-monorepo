/**
 * The rule the dashboard activity feed and the detail-page transaction tables share for the session's own rows once
 * services/convex has indexed the transaction: a session row is dropped when an indexed row has the same transaction
 * hash and the same action kind. One atomic batch has one hash and can emit several indexed rows of different kinds
 * (a pledge and a borrow), so a matching hash alone is not enough. A session row without a transaction hash yet stays.
 */

const TX_HASH = /^0x[0-9a-fA-F]{64}$/

/** Indexed kinds the session names differently: a reduced collateral is the session's withdrawal. */
const SESSION_KIND: Readonly<Record<string, string>> = { reduce: "withdraw" }

export type ActionRef = { txHash?: string | null; kind: string }

const actionKey = (txHash: string, kind: string) => `${txHash.toLowerCase()}\u0000${SESSION_KIND[kind] ?? kind}`

/** The session rows no indexed row covers, in their order. */
export function withoutIndexedSessionRows<S extends ActionRef>(
  sessionRows: readonly S[],
  indexedRows: readonly ActionRef[],
): S[] {
  const indexed = new Set<string>()
  for (const row of indexedRows) {
    if (row.txHash && TX_HASH.test(row.txHash)) indexed.add(actionKey(row.txHash, row.kind))
  }
  if (indexed.size === 0) return [...sessionRows]
  return sessionRows.filter(
    (row) => !row.txHash || !TX_HASH.test(row.txHash) || !indexed.has(actionKey(row.txHash, row.kind)),
  )
}
