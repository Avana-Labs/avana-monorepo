// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Oracle pokes: `poke()` on every LPOracle and DebtOracle on each new round of any of its feeds and at least once
// per feed heartbeat, so cached prices, first disagreement observations, the hourly checkpoint and the grace latch
// are stored (Q-199, Q-248, EMG-035). `poke()` is permissionless and pays nothing.

import { type Address, encodeFunctionData, parseAbi } from "viem";
import type { BlockContext, Job } from "../types.ts";

const pokeAbi = parseAbi(["function poke() returns (uint8 state)"]);

interface OracleTarget {
  readonly oracle: Address;
  readonly implementation: Address;
  readonly feeds: readonly { readonly feed: Address; readonly heartbeatSeconds: number }[];
}

/** Last poke and last round seen per oracle; kept in memory, rebuilt from reads after a restart. */
export class PokeBook {
  readonly lastPokeAt = new Map<Address, bigint>();
  readonly lastRound = new Map<Address, bigint>();
}

/** Due when any feed has a new round since the last poke, or a heartbeat has passed since it. */
export function pokeDue(now: bigint, lastPoke: bigint | undefined, minHeartbeat: number, newRound: boolean): boolean {
  if (lastPoke === undefined || newRound) return true;
  return now - lastPoke >= BigInt(minHeartbeat);
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
      if (t.feeds.length === 0) throw new Error(`oracle ${t.oracle} has no feed legs in the manifest`);
      const heartbeat = Math.min(...t.feeds.map((f) => f.heartbeatSeconds));
      if (!pokeDue(ctx.blockTimestamp, book.lastPokeAt.get(t.oracle), heartbeat, newRound)) return { act: false, reason: "notDue" };
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
