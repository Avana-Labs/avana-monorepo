// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Oracle pokes (3.6 REQ-ORACLE-037): `poke()` on every LPOracle and DebtOracle on each new round of any of its feeds,
// and at least once per CHECKPOINT_INTERVAL (3,600 s) or per heartbeat of its fastest leg, whichever is shorter, so
// cached prices, first disagreement observations, the hourly checkpoint and the grace latch are stored (Q-199, Q-248,
// EMG-035). A poke is sent POKE_LEAD_SECONDS before the interval ends, so the transaction lands inside it.
// `poke()` is permissionless and pays nothing.

import { type Address, encodeFunctionData, parseAbi } from "viem";
import type { BlockContext, Job } from "../types.ts";

const pokeAbi = parseAbi(["function poke() returns (uint8 state)"]);

export interface OracleTarget {
  readonly oracle: Address;
  readonly implementation: Address;
  readonly feeds: readonly { readonly feed: Address; readonly heartbeatSeconds: number }[];
}

/** Last poke and last round seen per oracle; kept in memory, rebuilt from reads after a restart. */
export class PokeBook {
  readonly lastPokeAt = new Map<Address, bigint>();
  readonly lastRound = new Map<Address, bigint>();
}

/** The oracles' CHECKPOINT_INTERVAL: the longest gap REQ-ORACLE-037 allows between two pokes of one oracle. */
export const CHECKPOINT_INTERVAL_SECONDS = 3_600;

/** How long before the interval ends a poke is sent, so it is mined inside it (5 Ethereum, 30 Base blocks). */
export const POKE_LEAD_SECONDS = 60;

/**
 * The longest gap allowed between two pokes of one oracle: CHECKPOINT_INTERVAL, or the heartbeat of its fastest leg
 * when that is shorter. A heartbeat that is not a positive finite number never lengthens the interval.
 */
export function pokeIntervalSeconds(heartbeats: readonly number[]): number {
  const valid = heartbeats.filter((h) => Number.isFinite(h) && h > 0);
  return Math.min(CHECKPOINT_INTERVAL_SECONDS, ...valid);
}

/** Due on the first sight, when any feed has a new round since the last poke, or when the interval less the lead has passed. */
export function pokeDue(now: bigint, lastPoke: bigint | undefined, intervalSeconds: number, newRound: boolean): boolean {
  if (lastPoke === undefined || newRound) return true;
  const wait = Math.max(0, Math.floor(intervalSeconds) - POKE_LEAD_SECONDS);
  return now - lastPoke >= BigInt(wait);
}

export function oraclePokeJob(book: PokeBook): Job<OracleTarget, OracleTarget> {
  return {
    kind: "oraclePoke",

    async discover(ctx: BlockContext) {
      const m = ctx.config.manifest;
      const lp = m.markets.map((x) => ({ oracle: x.lpOracle.address, implementation: x.lpOracle.implementation, feeds: x.feeds }));
      const debt = m.debtReserves.flatMap((r) => (r.debtOracle ? [{ oracle: r.debtOracle.address, implementation: r.debtOracle.implementation, feeds: r.feeds }] : []));
      return [...lp, ...debt];
    },

    async check(ctx, t) {
      let newRound = false;
      for (const f of t.feeds) {
        const [roundId] = await ctx.reader.feedRound(f.feed);
        if (book.lastRound.get(f.feed) !== roundId) {
          newRound = true;
          book.lastRound.set(f.feed, roundId);
        }
      }
      // An oracle with no feed legs in the manifest is still poked every CHECKPOINT_INTERVAL.
      const interval = pokeIntervalSeconds(t.feeds.map((f) => f.heartbeatSeconds));
      if (!pokeDue(ctx.blockTimestamp, book.lastPokeAt.get(t.oracle), interval, newRound)) return { act: false, reason: "notDue" };
      return { act: true, decision: t };
    },

    async build(ctx, t) {
      book.lastPokeAt.set(t.oracle, ctx.blockTimestamp);
      return {
        job: "oraclePoke",
        subject: `${ctx.config.chain.id}:${t.oracle}`,
        to: t.oracle,
        data: encodeFunctionData({ abi: pokeAbi, functionName: "poke" }),
        deadline: null,
        reservations: [],
        targets: [{ kind: "upgradeable", address: t.oracle, implementation: t.implementation }],
        params: { oracle: t.oracle },
      };
    },
  };
}
