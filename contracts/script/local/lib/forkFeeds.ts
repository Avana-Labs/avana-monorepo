// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The feeds of the forked chains, from contracts/script/local/fork-feeds.json (local only). Each listed token has four
// single-feed USD routes (primary, alternate, standby, second). On a fork:
//   - a token with a real Chainlink USD feed keeps it as primary: the proxy stays, its aggregator is etched with a mock
//     seeded from the latest round at the fork block, so the stack can move the price;
//   - every other slot is a local mock feed, seeded from the primary's round;
//   - a token with no real USD feed gets mocks in all four slots, seeded from its pool's TWAP against a quote token
//     whose own price comes from its feeds.
// This module plans the slots and computes the seeds; the fork-world step deploys the mocks and etches the aggregators
// with it, and writes the result into world.json's `feeds` in the shape the deploy scripts read.

import { type Address, getAddress, isAddress } from "viem";

export const SLOTS = ["primary", "alternate", "standby", "second"] as const;
export type Slot = (typeof SLOTS)[number];

export interface ForkFeedEntry {
  /** The real Chainlink USD feed proxy (read on the fork); "" until read. */
  primary?: string;
  /** No real USD feed: seed every slot from the pool `pair` ("TOKEN/OTHER", the token's market pool) against `quote`. */
  twap?: { pair: string; quote: string };
}

export type SlotPlan =
  | { kind: "real"; proxy: Address }
  | { kind: "mock"; seed: { from: "primary" } | { from: "twap"; pair: string; quote: string } };
export type FeedPlan = Record<string, Record<Slot, SlotPlan>>;

/** The network's entries of fork-feeds.json, checked: each is a real feed or a TWAP seed, never both. */
export function loadForkFeeds(file: Record<string, unknown>, network: string): Record<string, ForkFeedEntry> {
  const raw = file[network];
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) throw new Error(`fork-feeds.json has no ${network}`);
  const errors: string[] = [];
  const out: Record<string, ForkFeedEntry> = {};
  for (const [symbol, e] of Object.entries(raw as Record<string, ForkFeedEntry>)) {
    const has = { primary: e.primary !== undefined, twap: e.twap !== undefined };
    if (has.primary === has.twap) errors.push(`${network}.${symbol}: give either primary (a real feed) or twap`);
    if (has.primary && e.primary !== "" && !isAddress(e.primary!, { strict: false })) errors.push(`${network}.${symbol}.primary is not an address`);
    if (e.twap) {
      const [a, b] = e.twap.pair.split("/");
      if (!a || !b || ![a, b].includes(symbol) || ![a, b].includes(e.twap.quote) || e.twap.quote === symbol) errors.push(`${network}.${symbol}.twap: pair "${e.twap.pair}" must be ${symbol} and quote ${e.twap.quote}`);
    }
    out[symbol] = e;
  }
  if (errors.length) throw new Error(`fork-feeds.json refused:\n- ${errors.join("\n- ")}`);
  return out;
}

/** Each token's four slots. Refuses a token with no entry, a real feed not read yet, or a TWAP quote with no feed. */
export function planFeeds(entries: Record<string, ForkFeedEntry>, symbols: readonly string[]): FeedPlan {
  const errors: string[] = [];
  const plan: FeedPlan = {};
  for (const s of new Set(symbols)) {
    const e = entries[s];
    if (!e) {
      errors.push(`${s}: no entry in fork-feeds.json`);
      continue;
    }
    if (e.primary !== undefined) {
      if (e.primary === "") {
        errors.push(`${s}: primary feed not read from the fork yet`);
        continue;
      }
      const mock: SlotPlan = { kind: "mock", seed: { from: "primary" } };
      plan[s] = { primary: { kind: "real", proxy: getAddress(e.primary) }, alternate: mock, standby: mock, second: mock };
    } else {
      const q = entries[e.twap!.quote];
      if (!q?.primary) errors.push(`${s}: quote ${e.twap!.quote} needs a real feed to price the TWAP`);
      const mock: SlotPlan = { kind: "mock", seed: { from: "twap", pair: e.twap!.pair, quote: e.twap!.quote } };
      plan[s] = { primary: mock, alternate: mock, standby: mock, second: mock };
    }
  }
  if (errors.length) throw new Error(`fork feeds:\n- ${errors.join("\n- ")}`);
  return plan;
}

/**
 * A token's USD answer from a pool's mean tick: the token's price in the quote token times the quote's USD answer.
 * Uniswap's tick prices token0 in token1 units as 1.0001^tick x 10^(decimals0 - decimals1).
 */
export function twapUsdAnswer(a: { meanTick: number; tokenIsToken0: boolean; tokenDecimals: number; quoteDecimals: number; quoteAnswer: bigint; quoteFeedDecimals: number; feedDecimals: number }): bigint {
  const inQuote = 1.0001 ** (a.tokenIsToken0 ? a.meanTick : -a.meanTick) * 10 ** (a.tokenDecimals - a.quoteDecimals);
  const quoteUsd = Number(a.quoteAnswer) / 10 ** a.quoteFeedDecimals;
  const answer = Math.round(inQuote * quoteUsd * 10 ** a.feedDecimals);
  if (!Number.isFinite(answer) || answer <= 0) throw new Error(`no positive price from tick ${a.meanTick}`);
  return BigInt(answer);
}

/** A slot as deployed: the proxy the routes name and the aggregator behind it (the one the stack moves). */
export interface DeployedFeed {
  proxy: Address;
  aggregator: Address;
}

/** world.json's `feeds`: per token, each slot's proxy and `<slot>Aggregator`, as the test world writes them. */
export function worldFeeds(plan: FeedPlan, deployed: Record<string, Record<Slot, DeployedFeed>>): Record<string, Record<string, Address>> {
  const out: Record<string, Record<string, Address>> = {};
  for (const [s, slots] of Object.entries(plan)) {
    const d = deployed[s];
    if (!d) throw new Error(`${s}: no deployed feeds`);
    out[s] = {};
    for (const slot of SLOTS) {
      const f = d[slot];
      if (!f) throw new Error(`${s}.${slot}: not deployed`);
      if (slots[slot].kind === "real" && getAddress(f.proxy) !== (slots[slot] as { proxy: Address }).proxy) throw new Error(`${s}.${slot}: the real feed's proxy must stay ${(slots[slot] as { proxy: Address }).proxy}`);
      out[s][slot] = getAddress(f.proxy);
      out[s][`${slot}Aggregator`] = getAddress(f.aggregator);
    }
  }
  return out;
}
