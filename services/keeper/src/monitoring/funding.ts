// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// M-16 and M-17, read every block (services/README.md, Monitoring and alerting):
// - M-16, the keeper's debt-asset float per chain and asset: the funding Safe's balance less every open reservation
//   (InventoryBook.free), against the largest single debtToCover the chain's caps allow: below 150 % warns, below
//   100 % pages (REQ-SWAP-014: each committed operator holds at least that much).
// - M-17, the Aave V3 Pool's idle liquidity per debt asset as the helper can borrow it (`maxFlashLoan`): below 2x the
//   largest single debtToCover warns, below 1x pages (REQ-FLASH-008); and the signer's gas balance: below 3 days of
//   its median daily spend warns, below 1 day pages.
// The largest single debtToCover is configuration (KEEPER_LARGEST_DEBT_TO_COVER_<CHAIN>), set from each listing's
// REQ-FLASH-008 sizing; a debt asset without one warns until it is set. A page is sent only when the same read on the
// second provider at the same block agrees (`raise`).

import { type Address, type PublicClient, erc20Abi } from "viem";
import { flashLiquidatorAbi } from "@avana/protocol/abis";
import { type Alert, type AlertSink, raise } from "./alerts.ts";
import type { Level } from "./signals.ts";

const DAY = 86_400n;

/** M-16: free float against the largest debtToCover; 150 % warns, 100 % pages. */
export function m16Level(free: bigint, largest: bigint): Level {
  if (free < largest) return "page";
  if (free * 100n < largest * 150n) return "warn";
  return "ok";
}

/** M-17 idle liquidity: 2x warns, 1x pages. */
export function m17IdleLevel(idle: bigint, largest: bigint): Level {
  if (idle < largest) return "page";
  if (idle < largest * 2n) return "warn";
  return "ok";
}

/** M-17 gas: 3 days of daily spend warns, 1 day pages; nothing to judge without a spend. */
export function m17GasLevel(balance: bigint, dailySpend: bigint): Level {
  if (dailySpend <= 0n) return "ok";
  if (balance < dailySpend) return "page";
  if (balance < dailySpend * 3n) return "warn";
  return "ok";
}

/**
 * The signer's spend per UTC day, measured from its balance: every decrease between two reads is spend, an increase is
 * a top-up and is not counted. The median is over the complete days of the last `days`; the current day is not counted.
 */
export class SpendTracker {
  readonly #byDay = new Map<bigint, bigint>();
  #last: { balance: bigint; timestamp: bigint } | null = null;
  /** The first day watched from its start: the day after the first read. */
  #firstFullDay: bigint | null = null;

  constructor(readonly days = 7n) {}

  observe(balance: bigint, timestamp: bigint): void {
    const last = this.#last;
    if (this.#firstFullDay === null) this.#firstFullDay = timestamp / DAY + 1n;
    if (last && timestamp < last.timestamp) return;
    if (last && balance < last.balance) {
      const day = timestamp / DAY;
      this.#byDay.set(day, (this.#byDay.get(day) ?? 0n) + (last.balance - balance));
    }
    this.#last = { balance, timestamp };
    for (const d of this.#byDay.keys()) if (d < timestamp / DAY - this.days) this.#byDay.delete(d);
  }

  /** Median daily spend over the complete days watched in the last `days` (a watched day without spend counts as 0). */
  median(now: bigint): bigint | null {
    const today = now / DAY;
    const first = this.#firstFullDay;
    if (first === null || first >= today) return null;
    const values: bigint[] = [];
    for (let d = today - this.days > first ? today - this.days : first; d < today; d++) values.push(this.#byDay.get(d) ?? 0n);
    values.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
    const mid = values.length >> 1;
    return values.length % 2 === 1 ? values[mid]! : (values[mid - 1]! + values[mid]!) / 2n;
  }
}

/** Parses `KEEPER_LARGEST_DEBT_TO_COVER_<CHAIN>`: `asset:amount` pairs in the asset's base units, comma-separated. */
export function parseLargest(raw: readonly string[], name: string): Map<string, bigint> {
  const out = new Map<string, bigint>();
  for (const spec of raw) {
    const [asset, amount] = spec.split(":");
    if (!asset || !/^0x[0-9a-fA-F]{40}$/.test(asset) || !amount || !/^\d+$/.test(amount) || BigInt(amount) === 0n) {
      throw new Error(`${name} entry ${spec} is not asset:amount with a positive amount in base units`);
    }
    if (out.has(asset.toLowerCase())) throw new Error(`${name} names ${asset} twice`);
    out.set(asset.toLowerCase(), BigInt(amount));
  }
  return out;
}

export interface FundingDeps {
  readonly chainId: number;
  readonly primary: PublicClient;
  readonly fallback: PublicClient;
  readonly alerts: AlertSink;
  /** Debt assets of the chain's debt reserves (the manifest), each once. */
  readonly assets: readonly Address[];
  readonly fundingSafe: Address;
  readonly helper: Address;
  /** Largest single debtToCover per asset (lower-case), base units. */
  readonly largest: ReadonlyMap<string, bigint>;
  /** Free inventory after open reservations, from the Safe balance read at this block. */
  readonly free: (asset: Address, safeBalance: bigint) => bigint;
  /** The signer and its daily-spend floor (KEEPER_GAS_DAILY_SPEND_WEI_<CHAIN>); null in observe-only mode. */
  readonly gas: { readonly signer: Address; readonly dailyFloorWei: bigint; readonly spend: SpendTracker } | null;
}

/** Reads and judges M-16 and M-17 at one block; sends each non-ok level, a page only once confirmed. */
export function fundingCheck(d: FundingDeps) {
  const balanceOf = (c: PublicClient, asset: Address, blockNumber: bigint) =>
    c.readContract({ address: asset, abi: erc20Abi, functionName: "balanceOf", args: [d.fundingSafe], blockNumber });
  const idleOf = (c: PublicClient, asset: Address, blockNumber: bigint) =>
    c.readContract({ address: d.helper, abi: flashLiquidatorAbi, functionName: "maxFlashLoan", args: [asset], blockNumber });

  return async function check(head: { number: bigint; timestamp: bigint }): Promise<void> {
    const at = head.number;
    const send = (alert: Omit<Alert, "chainId" | "blockNumber">, confirm: () => Promise<boolean>) =>
      raise(d.alerts, { ...alert, chainId: d.chainId, blockNumber: at }, confirm);

    for (const asset of d.assets) {
      const largest = d.largest.get(asset.toLowerCase());
      if (largest === undefined) {
        await d.alerts.send({ signal: "M-16", level: "warn", chainId: d.chainId, blockNumber: at, subject: `float:${asset}`, detail: { asset, note: "largest debtToCover not configured (KEEPER_LARGEST_DEBT_TO_COVER)" } });
        continue;
      }
      const [safeBalance, idle] = await Promise.all([balanceOf(d.primary, asset, at), idleOf(d.primary, asset, at)]);
      const free = d.free(asset, safeBalance);
      const floatLevel = m16Level(free, largest);
      if (floatLevel !== "ok") {
        await send(
          { signal: "M-16", level: floatLevel, subject: `float:${asset}`, detail: { asset, free: free.toString(10), safeBalance: safeBalance.toString(10), largestDebtToCover: largest.toString(10), playbook: "P-09" } },
          async () => m16Level(d.free(asset, await balanceOf(d.fallback, asset, at)), largest) === "page",
        );
      }
      const idleLevel = m17IdleLevel(idle, largest);
      if (idleLevel !== "ok") {
        await send(
          { signal: "M-17", level: idleLevel, subject: `idle:${asset}`, detail: { asset, idle: idle.toString(10), largestDebtToCover: largest.toString(10), playbook: "P-08" } },
          async () => m17IdleLevel(await idleOf(d.fallback, asset, at), largest) === "page",
        );
      }
    }

    if (d.gas) {
      const g = d.gas;
      const balance = await d.primary.getBalance({ address: g.signer, blockNumber: at });
      g.spend.observe(balance, head.timestamp);
      const measured = g.spend.median(head.timestamp) ?? 0n;
      const daily = measured > g.dailyFloorWei ? measured : g.dailyFloorWei;
      const level = m17GasLevel(balance, daily);
      if (level !== "ok") {
        await send(
          { signal: "M-17", level, subject: `gas:${g.signer}`, detail: { signer: g.signer, balanceWei: balance.toString(10), dailySpendWei: daily.toString(10), measuredMedianWei: measured.toString(10), playbook: "P-08" } },
          async () => m17GasLevel(await d.fallback.getBalance({ address: g.signer, blockNumber: at }), daily) === "page",
        );
      }
    }
  };
}
