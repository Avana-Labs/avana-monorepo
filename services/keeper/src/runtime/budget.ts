// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The spend log and the daily budgets of the scheduled and lazy classes (keeper DESIGN.md, Fees):
// - every included transaction is recorded with its cost (gas used × effective gas price, plus the L1 data fee on
//   Base), its class, its market and the market's Hub (market → CDP Spoke from the manifest, Spoke → Hub from
//   `MarketRegistry.hubOf`);
// - a scheduled or lazy class whose spend in the rolling 24 h reaches its budget stops sending and pages (M-32 "class
//   budget reached") until older spend leaves the window; urgent is never budget-limited, only the per-transaction
//   ceiling applies to it;
// - M-31 spend anomaly: the rolling 24 h spend of every class above 3× the median daily spend of the last 7 complete
//   days warns, above 5× pages; the median is never taken below the expected daily spend (KEEPER_GAS_DAILY_SPEND_WEI).
// Both alerts judge the keeper's own spend log, not chain state, so there is no second-provider read to confirm them.
// The log is kept in memory: a restart starts a new window.

import { type Address, type Hex, decodeEventLog } from "viem";
import { lpVaultSwapAbi } from "@avana/protocol/abis";
import type { ServiceManifest } from "@avana/services-common";
import type { Alert } from "../monitoring/alerts.ts";
import type { Level } from "../monitoring/signals.ts";
import type { JobClass } from "../types.ts";

export const DAY_SECONDS = 86_400n;
/** Days of history the M-31 median reads. */
export const MEDIAN_DAYS = 7n;

/** One included transaction's cost. */
export interface SpendEntry {
  readonly chainId: number;
  readonly jobClass: JobClass;
  /** Unix seconds of the block it was seen included in. */
  readonly at: bigint;
  readonly costWei: bigint;
  /** The market ID (decimal) the subject names; null for a subject without one (a DebtOracle, a CDP Spoke). */
  readonly market: string | null;
  /** The Hub the subject's CDP Spoke draws from (lower-case); null when the Spoke or its Hub is not known. */
  readonly hub: Address | null;
}

export interface ClassBudgets {
  readonly scheduled: bigint;
  readonly lazy: bigint;
}

/** M-31: rolling 24 h spend above 3× the daily median warns, above 5× pages. */
export function m31Level(spent24h: bigint, dailyMedian: bigint): Level {
  if (dailyMedian <= 0n) return "ok";
  if (spent24h > dailyMedian * 5n) return "page";
  if (spent24h > dailyMedian * 3n) return "warn";
  return "ok";
}

/** The rolling 24 h spend log of one chain, with its class budgets. */
export class SpendBook {
  readonly #entries: SpendEntry[] = [];
  /** The first UTC day watched from its start: the day after the book was created or first written. */
  #firstFullDay: bigint | null = null;

  constructor(
    readonly chainId: number,
    /** Undefined: no class is limited (observe-only). */
    readonly budgets: ClassBudgets | undefined,
    /** The expected daily spend, the floor of the M-31 median. */
    readonly dailyFloorWei: bigint,
  ) {}

  /** Starts the watched days at `now` (the first processed head); later records never move it. */
  watchFrom(now: bigint): void {
    this.#firstFullDay ??= now / DAY_SECONDS + 1n;
  }

  record(e: SpendEntry): void {
    if (e.chainId !== this.chainId) throw new Error(`spend of chain ${e.chainId} recorded in the book of chain ${this.chainId}`);
    this.watchFrom(e.at);
    this.#entries.push(e);
    // Keep 8 days: the 7 complete days of the median and the current one.
    const keepFrom = (e.at / DAY_SECONDS - MEDIAN_DAYS) * DAY_SECONDS;
    while (this.#entries.length > 0 && this.#entries[0]!.at < keepFrom) this.#entries.shift();
  }

  /** Spend in (now − 24 h, now], of one class or of every class. */
  spent24h(now: bigint, jobClass?: JobClass): bigint {
    let sum = 0n;
    for (const e of this.#entries) if (e.at > now - DAY_SECONDS && e.at <= now && (jobClass === undefined || e.jobClass === jobClass)) sum += e.costWei;
    return sum;
  }

  /** Spend in the rolling 24 h per Hub (null: not attributed). */
  byHub24h(now: bigint): Map<Address | null, bigint> {
    const out = new Map<Address | null, bigint>();
    for (const e of this.#entries) if (e.at > now - DAY_SECONDS && e.at <= now) out.set(e.hub, (out.get(e.hub) ?? 0n) + e.costWei);
    return out;
  }

  /** The class's budget, or null for urgent (never limited) and without budgets. */
  budgetOf(jobClass: JobClass): bigint | null {
    if (jobClass === "urgent" || this.budgets === undefined) return null;
    return this.budgets[jobClass];
  }

  /** False once a scheduled or lazy class has spent its budget in the rolling 24 h; urgent is always allowed. */
  allows(jobClass: JobClass, now: bigint): boolean {
    const budget = this.budgetOf(jobClass);
    return budget === null || this.spent24h(now, jobClass) < budget;
  }

  /** Median daily spend over the complete UTC days watched in the last 7 (a day without spend counts as 0), at least the floor. */
  dailyMedian(now: bigint): bigint {
    const today = now / DAY_SECONDS;
    const first = this.#firstFullDay;
    if (first === null || first >= today) return this.dailyFloorWei;
    const byDay = new Map<bigint, bigint>();
    for (const e of this.#entries) byDay.set(e.at / DAY_SECONDS, (byDay.get(e.at / DAY_SECONDS) ?? 0n) + e.costWei);
    const values: bigint[] = [];
    for (let d = today - MEDIAN_DAYS > first ? today - MEDIAN_DAYS : first; d < today; d++) values.push(byDay.get(d) ?? 0n);
    values.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
    const mid = values.length >> 1;
    const median = values.length % 2 === 1 ? values[mid]! : (values[mid - 1]! + values[mid]!) / 2n;
    return median > this.dailyFloorWei ? median : this.dailyFloorWei;
  }

  /** M-31 and M-32 at one head: one alert per class at its budget (page), and the anomaly when not ok. */
  alerts(head: { number: bigint; timestamp: bigint }): Alert[] {
    const out: Alert[] = [];
    const now = head.timestamp;
    for (const jobClass of ["scheduled", "lazy"] as const) {
      const budget = this.budgetOf(jobClass);
      if (budget === null) continue;
      const spent = this.spent24h(now, jobClass);
      if (spent < budget) continue;
      out.push({ signal: "M-32", level: "page", chainId: this.chainId, blockNumber: head.number, subject: `budget:${jobClass}`, detail: { jobClass, spent24hWei: spent.toString(10), budgetWei: budget.toString(10), note: `${jobClass} transactions stopped until the 24 h spend falls below the budget` } });
    }
    const total = this.spent24h(now);
    const median = this.dailyMedian(now);
    const level = m31Level(total, median);
    if (level !== "ok") {
      const byClass = Object.fromEntries((["urgent", "scheduled", "lazy"] as const).map((c) => [`${c}24hWei`, this.spent24h(now, c).toString(10)]));
      out.push({ signal: "M-31", level, chainId: this.chainId, blockNumber: head.number, subject: "spend", detail: { spent24hWei: total.toString(10), dailyMedianWei: median.toString(10), ...byClass } });
    }
    return out;
  }
}

/** The subject without a reorg's `@nonce` suffix. */
const bare = (subject: string) => subject.split("@")[0]!;

/**
 * The market and CDP Spoke a transaction's subject names, from the manifest:
 * - `chainId:market:<marketId>` (breaker poke, `settlePending`): that market and its Spoke;
 * - `chainId:<spoke>:<proxy>` (liquidation): that Spoke; the market comes from the account (`marketOfAccount`);
 * - `chainId:<address>`: a market's LPOracle (that market), a DebtOracle (its reserve's Spoke) or a CDP Spoke.
 */
export function attributeSubject(manifest: Pick<ServiceManifest, "markets" | "debtReserves" | "aave">, subject: string, marketOfAccount?: (proxy: string) => bigint | undefined): { market: string | null; spoke: Address | null } {
  const parts = bare(subject).split(":");
  const eq = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
  const ofMarket = (id: bigint | undefined) => {
    const m = id === undefined ? undefined : manifest.markets.find((x) => x.marketId === id);
    return m ? { market: m.marketId.toString(10), spoke: m.spoke } : null;
  };
  if (parts.length === 3 && parts[1] === "market") return ofMarket(/^\d+$/.test(parts[2]!) ? BigInt(parts[2]!) : undefined) ?? { market: null, spoke: null };
  if (parts.length === 3) {
    const byAccount = ofMarket(marketOfAccount?.(parts[2]!));
    return { market: byAccount?.market ?? null, spoke: parts[1]! as Address };
  }
  if (parts.length === 2) {
    const a = parts[1]!;
    const lp = manifest.markets.find((m) => eq(m.lpOracle.address, a));
    if (lp) return { market: lp.marketId.toString(10), spoke: lp.spoke };
    const debt = manifest.debtReserves.find((r) => r.debtOracle !== null && eq(r.debtOracle.address, a));
    if (debt) return { market: null, spoke: debt.spoke };
    if (manifest.aave.borrowSpokes.some((s) => eq(s.address, a))) return { market: null, spoke: a as Address };
  }
  return { market: null, spoke: null };
}

/**
 * Spoke → Hub, read once per Spoke from `MarketRegistry.hubOf` and kept: a CDP Spoke's Hub does not change. A failed
 * read is not kept, so the next transaction tries again.
 */
export class HubBook {
  readonly #hubs = new Map<string, Address | null>();

  constructor(private readonly hubOf: (spoke: Address) => Promise<Address>) {}

  async of(spoke: Address | null): Promise<Address | null> {
    if (spoke === null) return null;
    const key = spoke.toLowerCase();
    if (this.#hubs.has(key)) return this.#hubs.get(key)!;
    try {
      const hub = (await this.hubOf(spoke)).toLowerCase() as Address;
      const known = /^0x0{40}$/.test(hub) ? null : hub;
      this.#hubs.set(key, known);
      return known;
    } catch {
      return null;
    }
  }
}

/**
 * The reward `Kr` of a liquidation from its receipt: `LiquidationSettled.report.keeperReward` (LIQ-031) emitted by
 * LPVaultSwap, in the debt asset's base units, with that asset. Null when the receipt holds no such event.
 */
export function liquidationReward(logs: readonly { readonly address: Address; readonly topics: readonly Hex[]; readonly data: Hex }[], lpVaultSwap: Address): { readonly keeperReward: bigint; readonly debtAsset: Address } | null {
  for (const l of logs) {
    if (l.address.toLowerCase() !== lpVaultSwap.toLowerCase()) continue;
    try {
      const ev = decodeEventLog({ abi: lpVaultSwapAbi, topics: l.topics as [Hex, ...Hex[]], data: l.data });
      if (ev.eventName !== "LiquidationSettled") continue;
      const report = (ev.args as unknown as { report: { keeperReward: bigint; debtAsset: Address } }).report;
      return { keeperReward: report.keeperReward, debtAsset: report.debtAsset };
    } catch {
      continue;
    }
  }
  return null;
}
