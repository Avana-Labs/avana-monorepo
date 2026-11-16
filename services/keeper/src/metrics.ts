// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The keeper's Prometheus text at GET /metrics (KEEPER_METRICS_PORT). Dashboards are built on these names and labels;
// keep them stable. `chain` is the chain key of @avana/services-common (mainnet, base, sepolia, baseSepolia, anvil).
//
//   keeper_mode{chain,mode}                     1 for the effective mode: active, observe or halted
//   keeper_head_block{chain}                    last head this instance finished processing (the monitor heartbeat)
//   keeper_indexer_block{chain}                 last block the indexer stream reported fully handled
//   keeper_rpc_backfill_block{chain}            block the RPC log backfill has read to on both providers
//   keeper_discovered_accounts{chain}           accounts in the cache (the union of both discovery sources)
//   keeper_discovery_one_sided{chain,only}      accounts only one source holds (M-30); only = indexer | rpc
//   keeper_alerts_open{chain,signal,level}      alerts raised for the last processed head (a held condition is
//                                               re-sent every block, so this is what is open at the monitor)
//   keeper_alerts_total{chain,signal,level}     alerts raised since the process started (counter)
//   keeper_gas_spend_24h_wei{chain,class}       gas spent by included transactions in the rolling 24 h, by fee class
//   keeper_gas_spend_wei_total{chain,class,hub} gas spent by included transactions since the process started (counter);
//                                               hub = the subject's Hub, lower-case, or "unknown"
//   keeper_small_account_gas_wei_total{chain,hub}      gas spent on liquidations whose reward Kr (LiquidationSettled
//                                               `keeperReward`, valued in wei) was below the call's gas cost (counter, D4)
//   keeper_small_account_liquidations_total{chain,hub} those liquidations (counter)
//
// A gauge with no value yet (no head processed, a source not read) is left out rather than written as 0.

import type { Alert } from "./monitoring/alerts.ts";
import type { JobClass } from "./types.ts";

/** The label of a spend whose Hub is not known. */
export const UNKNOWN_HUB = "unknown";

/**
 * Avana's gas spend on small accounts (D4): liquidations whose reward did not cover their gas, per Hub. The rule uses the
 * waterfall the contract already emits: the call counts when `Kr` (`LiquidationSettled.report.keeperReward`), valued in
 * wei, is below the call's gas cost (gas used × effective gas price, plus the L1 data fee). Reported, never alerted.
 */
export class SmallAccountSpend {
  readonly #byHub = new Map<string, { gasWei: bigint; count: number }>();

  /** Records one liquidation; true when it counted (its reward was below its gas cost). */
  record(l: { readonly hub: string | null; readonly gasCostWei: bigint; readonly rewardWei: bigint }): boolean {
    if (l.rewardWei >= l.gasCostWei) return false;
    const key = l.hub ?? UNKNOWN_HUB;
    const cur = this.#byHub.get(key) ?? { gasWei: 0n, count: 0 };
    this.#byHub.set(key, { gasWei: cur.gasWei + l.gasCostWei, count: cur.count + 1 });
    return true;
  }

  byHub(): ReadonlyMap<string, { readonly gasWei: bigint; readonly count: number }> {
    return this.#byHub;
  }
}

/**
 * A debt-asset amount in wei of the chain's gas token, from USD prices with their decimals:
 * amount × assetUsd / 10^assetDecimals × 10^18 / nativeUsd (both prices in the same USD decimals), rounded down.
 */
export function valueInWei(amount: bigint, assetDecimals: number, assetUsd: bigint, nativeUsd: bigint): bigint {
  if (nativeUsd <= 0n) throw new Error("valueInWei: the gas token price must be positive");
  return (amount * assetUsd * 10n ** 18n) / (10n ** BigInt(assetDecimals) * nativeUsd);
}

/** What one chain's loop has reported; updated by main.ts, read at each scrape. */
export class ChainMetrics {
  head: bigint | null = null;
  indexedBlock: bigint | null = null;
  rpcThrough: bigint | null = null;
  accounts: number | null = null;
  oneSided: { indexer: number; rpc: number } | null = null;
  /** Rolling 24 h spend per fee class, set at each head from the spend log; null before the first head. */
  spend24h: ReadonlyMap<JobClass, bigint> | null = null;
  readonly smallAccounts = new SmallAccountSpend();
  readonly #spendTotal = new Map<string, bigint>();

  /** Adds one included transaction's cost to the spend counter. */
  spent(s: { readonly jobClass: JobClass; readonly hub: string | null; readonly costWei: bigint }): void {
    const key = `${s.jobClass}|${s.hub ?? UNKNOWN_HUB}`;
    this.#spendTotal.set(key, (this.#spendTotal.get(key) ?? 0n) + s.costWei);
  }

  spendTotal(): ReadonlyMap<string, bigint> {
    return this.#spendTotal;
  }
  readonly #total = new Map<string, number>();
  /** Alerts of the head being processed; becomes `#open` when the head is reported processed. */
  #building: { block: bigint; counts: Map<string, number> } = { block: -1n, counts: new Map() };
  #open = new Map<string, number>();

  /** Counts one alert sent; called by the alert sink for every alert, before it is posted. */
  alert(a: Alert): void {
    const key = `${a.signal}|${a.level}`;
    this.#total.set(key, (this.#total.get(key) ?? 0) + 1);
    if (a.blockNumber > this.#building.block) this.#building = { block: a.blockNumber, counts: new Map() };
    if (a.blockNumber === this.#building.block) inc(this.#building.counts, key);
    // An alert raised outside the pass (the gas ceiling) for the head already processed.
    if (a.blockNumber === this.head) inc(this.#open, key);
  }

  /** The head is processed: its alerts become the open set. */
  processed(head: bigint): void {
    this.head = head;
    this.#open = this.#building.block === head ? new Map(this.#building.counts) : new Map();
  }

  open(): ReadonlyMap<string, number> {
    return this.#open;
  }

  total(): ReadonlyMap<string, number> {
    return this.#total;
  }
}

const inc = (m: Map<string, number>, key: string) => m.set(key, (m.get(key) ?? 0) + 1);

export interface ChainSample {
  readonly chain: string;
  readonly mode: "active" | "observe" | "halted";
  readonly metrics: ChainMetrics;
}

/** Label value escaping of the text format: backslash, double quote and newline. */
const esc = (v: string) => v.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n");
const labels = (l: Readonly<Record<string, string>>) => `{${Object.entries(l).map(([k, v]) => `${k}="${esc(v)}"`).join(",")}}`;

/** The text format of every chain's metrics; each family's samples are written together under its HELP and TYPE. */
export function renderMetrics(chains: readonly ChainSample[]): string {
  const out: string[] = [];
  const family = (name: string, type: "gauge" | "counter", help: string, samples: readonly [Readonly<Record<string, string>>, bigint | number][]) => {
    out.push(`# HELP ${name} ${help}`, `# TYPE ${name} ${type}`);
    for (const [l, v] of samples) out.push(`${name}${labels(l)} ${v.toString(10)}`);
  };
  const each = <T>(pick: (c: ChainSample) => T | null, row: (c: ChainSample, v: T) => [Record<string, string>, bigint | number][]) =>
    chains.flatMap((c) => {
      const v = pick(c);
      return v === null ? [] : row(c, v);
    });
  const bySignal = (c: ChainSample, m: ReadonlyMap<string, number>): [Record<string, string>, number][] =>
    [...m.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([key, n]) => {
      const [signal, level] = key.split("|") as [string, string];
      return [{ chain: c.chain, signal, level }, n];
    });

  family("keeper_mode", "gauge", "Effective mode of the instance on the chain (1 for the current mode).", chains.map((c) => [{ chain: c.chain, mode: c.mode }, 1]));
  family("keeper_head_block", "gauge", "Last head the instance finished processing.", each((c) => c.metrics.head, (c, v) => [[{ chain: c.chain }, v]]));
  family("keeper_indexer_block", "gauge", "Last block the indexer stream reported fully handled.", each((c) => c.metrics.indexedBlock, (c, v) => [[{ chain: c.chain }, v]]));
  family("keeper_rpc_backfill_block", "gauge", "Block the RPC log backfill has read to on both providers.", each((c) => c.metrics.rpcThrough, (c, v) => [[{ chain: c.chain }, v]]));
  family("keeper_discovered_accounts", "gauge", "Accounts in the keeper's cache (union of the indexer stream and the RPC backfill).", each((c) => c.metrics.accounts, (c, v) => [[{ chain: c.chain }, v]]));
  family("keeper_discovery_one_sided", "gauge", "Accounts only one discovery source holds, by the source that holds them (M-30).", each((c) => c.metrics.oneSided, (c, v) => [[{ chain: c.chain, only: "indexer" }, v.indexer], [{ chain: c.chain, only: "rpc" }, v.rpc]]));
  family("keeper_alerts_open", "gauge", "Alerts raised for the last processed head, by signal and level.", chains.flatMap((c) => bySignal(c, c.metrics.open())));
  family("keeper_alerts_total", "counter", "Alerts raised since the process started, by signal and level.", chains.flatMap((c) => bySignal(c, c.metrics.total())));
  family("keeper_gas_spend_24h_wei", "gauge", "Gas spent by included transactions in the rolling 24 h, by fee class.", each((c) => c.metrics.spend24h, (c, v) => [...v.entries()].map(([cls, wei]) => [{ chain: c.chain, class: cls }, wei])));
  family("keeper_gas_spend_wei_total", "counter", "Gas spent by included transactions since the process started, by fee class and Hub.", chains.flatMap((c) =>
    [...c.metrics.spendTotal().entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([key, wei]): [Record<string, string>, bigint] => {
      const [cls, hub] = key.split("|") as [string, string];
      return [{ chain: c.chain, class: cls, hub }, wei];
    })));
  const small = (c: ChainSample) => [...c.metrics.smallAccounts.byHub().entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  family("keeper_small_account_gas_wei_total", "counter", "Gas spent on liquidations whose reward was below their gas cost, by Hub (D4).", chains.flatMap((c) => small(c).map(([hub, v]): [Record<string, string>, bigint] => [{ chain: c.chain, hub }, v.gasWei])));
  family("keeper_small_account_liquidations_total", "counter", "Liquidations whose reward was below their gas cost, by Hub (D4).", chains.flatMap((c) => small(c).map(([hub, v]): [Record<string, string>, number] => [{ chain: c.chain, hub }, v.count])));
  return `${out.join("\n")}\n`;
}
