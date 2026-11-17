// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The chain's AvanaGasVault (2.24), read from the chain, not from the keeper (EMG-115):
// - M-35, vault runway: the vault's balance against its daily top-up rate. Under 30 days warns, under 14 days pages:
//   a treasury Safe refill or a bridge needs a quorum and a few days. The rate is what the vault sent (`ToppedUp`)
//   over the last 30 days divided by the days watched (at least one): top-ups are lumpy, one refill covers several
//   days, so the median of daily totals would be 0 on most days and hide the drain. The rate is never below the
//   expected daily spend of MONITOR_GAS_VAULT_DAILY_WEI (`chain:wei`, when set), which also covers the first day; with neither
//   a watched day nor that floor, nothing is judged.
// - M-36, top-up capped: every `ToppedUp` whose amount is below what the signer requested (its 24 h cap or the vault's
//   balance limited it) and every `TopUpFailed` (the signer could not receive) pages once.
// The logs are read from the vault's deployment block, at most MAX_RANGE blocks a round, and the runway is judged
// once the reads have caught up with the head. Pages are confirmed on the second provider over the same range.

import { avanaGasVaultAbi } from "@avana/protocol/abis";
import { some } from "@avana/services-common/views";
import { type Address, type Hex, decodeEventLog, encodeEventTopics, multicall3Abi } from "viem";
import { MULTICALL3_ADDRESS } from "@avana/services-common/chains";
import { type Probe, type RawLog, text } from "../probe.ts";
import type { Level } from "../signals.ts";
import type { Finding } from "../types.ts";

export const RUNWAY_WARN_DAYS = 30n;
export const RUNWAY_PAGE_DAYS = 14n;
const DAY = 86_400;
const WINDOW = 30 * DAY;
const MAX_RANGE = 2_000n;

const TOPPED_UP = encodeEventTopics({ abi: avanaGasVaultAbi, eventName: "ToppedUp" })[0] as Hex;
const TOP_UP_FAILED = encodeEventTopics({ abi: avanaGasVaultAbi, eventName: "TopUpFailed" })[0] as Hex;

export interface TopUpEvent {
  readonly kind: "ToppedUp" | "TopUpFailed";
  readonly signer: Address;
  readonly amount: bigint;
  /** `targetBalance − balance` before the send; equal to `amount` for a failed send. */
  readonly requested: bigint;
  readonly block: bigint;
  readonly tx: Hex;
  readonly logIndex: number;
}

export interface GasVaultInput {
  /** null: no vault in the manifest. */
  readonly vault: Address | null;
  readonly now: number;
  /** null: the balance read failed this round. */
  readonly balance: bigint | null;
  readonly from: bigint;
  readonly to: bigint;
  readonly head: bigint;
  readonly events: readonly TopUpEvent[];
}

export const runwaySubject = (vault: Address) => `gasVault:${vault.toLowerCase()}:runway`;
export const topUpSubject = (e: Pick<TopUpEvent, "tx" | "logIndex">) => `gasVault:topUp:${e.tx}:${e.logIndex}`;

/** M-35: runway in whole days of `dailyWei`; under 14 pages, under 30 warns; nothing to judge without a rate. */
export function m35(balance: bigint, dailyWei: bigint): Level {
  if (dailyWei <= 0n) return "ok";
  if (balance < dailyWei * RUNWAY_PAGE_DAYS) return "page";
  if (balance < dailyWei * RUNWAY_WARN_DAYS) return "warn";
  return "ok";
}

/** Daily rate of `sent` over the window watched: `[watchedFrom, now]`, at most 30 days, at least one day. */
export function dailyRate(sent: readonly { t: number; amount: bigint }[], watchedFrom: number, now: number): bigint {
  const since = Math.max(watchedFrom, now - WINDOW);
  const total = sent.filter((x) => x.t > now - WINDOW).reduce((s, x) => s + x.amount, 0n);
  const days = BigInt(Math.max(1, Math.floor((now - since) / DAY)));
  return total / days;
}

function decode(l: RawLog): TopUpEvent | null {
  try {
    const d = decodeEventLog({ abi: avanaGasVaultAbi, data: l.data, topics: l.topics as [Hex, ...Hex[]] });
    const base = { block: l.blockNumber, tx: l.transactionHash, logIndex: l.logIndex };
    if (d.eventName === "ToppedUp") return { kind: "ToppedUp", signer: d.args.signer, amount: d.args.amount, requested: d.args.requested, ...base };
    if (d.eventName === "TopUpFailed") return { kind: "TopUpFailed", signer: d.args.signer, amount: d.args.amount, requested: d.args.amount, ...base };
  } catch {
    // Not one of the two events.
  }
  return null;
}

/** `expectedDailyWei`: the chain's entry of MONITOR_GAS_VAULT_DAILY_WEI, the floor of the runway rate. */
export function gasVaultProbe(expectedDailyWei: bigint | null = null): Probe<GasVaultInput> {
  let next: bigint | null = null;
  let range: { head: bigint; from: bigint } | null = null;
  /** Top-ups sent in the last 30 days, by the time of the round that read them. */
  let sent: { t: number; amount: bigint }[] = [];
  /** Time of the round that first read a log range: the start of the watched window. */
  let watchedFrom: number | null = null;

  return {
    name: "gasVault",

    async read(ctx) {
      const v = ctx.manifest.avana.gasVault;
      const head = ctx.block.number;
      if (!v) return { vault: null, now: ctx.block.timestamp, balance: null, from: head + 1n, to: head, head, events: [] };
      const from = range?.head === head ? range.from : (next ?? BigInt(v.startBlock));
      range = { head, from };
      const to = from + MAX_RANGE - 1n < head ? from + MAX_RANGE - 1n : head;
      const [balance] = await some(ctx.views, [{ address: MULTICALL3_ADDRESS, abi: multicall3Abi, functionName: "getEthBalance", args: [v.address] }]);
      const logs = from > to ? [] : await ctx.rpc.getLogs([v.address], [TOPPED_UP, TOP_UP_FAILED], from, to);
      const events = logs.filter((l) => l.address.toLowerCase() === v.address.toLowerCase()).map(decode).filter((e): e is TopUpEvent => e !== null);
      return { vault: v.address, now: ctx.block.timestamp, balance: typeof balance === "bigint" ? balance : null, from, to, head, events };
    },

    evaluate(input) {
      if (!input.vault) return [];
      next = input.to + 1n;
      watchedFrom ??= input.now;
      const out: Finding[] = [];
      for (const e of input.events) {
        if (e.kind === "ToppedUp") sent.push({ t: input.now, amount: e.amount });
        const capped = e.kind === "TopUpFailed" || e.amount < e.requested;
        if (!capped) continue;
        out.push({
          signal: "M-36",
          kind: "event",
          level: "page",
          subject: topUpSubject(e),
          detail: { event: e.kind, vault: input.vault, signer: e.signer, amount: e.amount.toString(10), requested: e.requested.toString(10), tx: e.tx, block: e.block.toString(10), playbook: "P-22 (EMG-115)" },
        });
      }
      sent = sent.filter((x) => x.t > input.now - WINDOW);

      const subject = runwaySubject(input.vault);
      if (input.balance === null || input.to < input.head) {
        out.push({ signal: "M-35", kind: "unread", level: "ok", subject, detail: {} });
        return out;
      }
      const measured = input.now - watchedFrom >= DAY ? dailyRate(sent, watchedFrom, input.now) : 0n;
      const floor = expectedDailyWei ?? 0n;
      const rate = measured > floor ? measured : floor;
      const runwayDays = rate > 0n ? (input.balance / rate).toString(10) : "unbounded";
      out.push({
        signal: "M-35",
        kind: "condition",
        level: m35(input.balance, rate),
        subject,
        detail: { vault: input.vault, balanceWei: input.balance.toString(10), dailyTopUpWei: rate.toString(10), measuredDailyWei: measured.toString(10), runwayDays, warnBelowDays: RUNWAY_WARN_DAYS.toString(10), pageBelowDays: RUNWAY_PAGE_DAYS.toString(10), playbook: "P-22 (EMG-115)" },
      });
      return out;
    },

    evidence(input, subject) {
      if (subject.startsWith("gasVault:topUp:")) {
        const e = input.events.find((x) => topUpSubject(x) === subject);
        return e ? text(e) : null;
      }
      return input.vault && subject === runwaySubject(input.vault) && input.balance !== null ? text({ balance: input.balance }) : null;
    },

    save() {
      return { next: next?.toString(10) ?? null, watchedFrom, sent: sent.map((x) => ({ t: x.t, amount: x.amount.toString(10) })) };
    },

    restore(state) {
      const s = state as { next: string | null; watchedFrom: number | null; sent: { t: number; amount: string }[] } | null;
      if (!s) return;
      next = s.next === null ? null : BigInt(s.next);
      watchedFrom = s.watchedFrom;
      sent = s.sent.map((x) => ({ t: x.t, amount: BigInt(x.amount) }));
    },
  };
}
