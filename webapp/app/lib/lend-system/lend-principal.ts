import { formatUnits } from "viem"
import type { LendHubAsset } from "@/app/lib/lend-system/chain-lend-positions"

/**
 * A wallet's Lend principal per market: Σ supplied − Σ withdrawn over the wallet's whole history of Lend Spoke
 * `Supply` and `Withdraw` events (services/convex `wallet.history.older`, every page on every chain), counting only
 * events whose `user` is the wallet. Null when the history cannot be read in full, so the caller keeps principal =
 * current supply (Earned shows $0) instead of a wrong number.
 */

/** One export record of `wallet.history.older` (services/common `ExportRecord`), the fields read here. */
export type HistoryRecordLike = { key: string; kind: string; address: string; args: Readonly<Record<string, unknown>> }

export type OlderHistoryLike =
  | { status: "ok"; records: readonly HistoryRecordLike[]; next: string | null }
  | { status: "unavailable" | "rateLimited" }

/** Pages read per chain at most (100 records each). */
const MAX_PAGES = 50

/** Every record of the wallet on one chain, newest page first; null when any page is refused or the read fails. */
export async function readFullHistory(
  older: (args: { chainId: number; wallet: string; before?: string }) => Promise<OlderHistoryLike>,
  chainId: number,
  wallet: string,
): Promise<HistoryRecordLike[] | null> {
  const records: HistoryRecordLike[] = []
  let before: string | undefined
  for (let page = 0; page < MAX_PAGES; page++) {
    let answer: OlderHistoryLike
    try {
      answer = await older({ chainId, wallet, ...(before ? { before } : {}) })
    } catch {
      return null
    }
    if (answer.status !== "ok") return null
    records.push(...answer.records)
    if (!answer.next) return records
    before = answer.next
  }
  // More pages than read: incomplete.
  return null
}

/** Whole-token principal per Lend market slug, from every chain's full history. */
export function lendPrincipal(
  wallet: string,
  historyByChain: ReadonlyMap<number, readonly HistoryRecordLike[]>,
  hubAssets: readonly LendHubAsset[],
): Record<string, number> {
  const units = new Map<string, bigint>()
  const slugOf = new Map<string, LendHubAsset>()
  for (const asset of hubAssets) {
    for (const r of asset.lendReserves) slugOf.set(`${asset.chainId}:${r.spoke.toLowerCase()}:${r.reserveId}`, asset)
  }
  const user = wallet.toLowerCase()
  for (const [chainId, records] of historyByChain) {
    for (const record of records) {
      const sign = record.kind === "AaveSpoke.Supply" ? 1n : record.kind === "AaveSpoke.Withdraw" ? -1n : 0n
      if (sign === 0n || String(record.args.user ?? "").toLowerCase() !== user) continue
      const asset = slugOf.get(`${chainId}:${record.address.toLowerCase()}:${String(record.args.reserveId)}`)
      if (!asset) continue
      const amount = BigInt(String(sign > 0n ? record.args.suppliedAmount : record.args.withdrawnAmount))
      units.set(asset.slug, (units.get(asset.slug) ?? 0n) + sign * amount)
    }
  }
  const out: Record<string, number> = {}
  for (const asset of hubAssets) {
    const total = units.get(asset.slug)
    if (total !== undefined) out[asset.slug] = Number(formatUnits(total > 0n ? total : 0n, asset.decimals))
  }
  return out
}
