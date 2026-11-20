// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Oracle signals: M-03 the age of every Chainlink leg of the markets' LPOracles (LPOracle.feedsOf, recorded in the
// manifest) and M-04 the age of every debt reserve's Chainlink feed, each against the heartbeat the manifest records.
// A leg past its heartbeat warns; past 1.5 heartbeats it pages, since the LPOracle then refuses to price (M-01). M-02
// is retired: the stateless LPOracle records no disagreement.

import { some } from "@avana/services-common/views";
import { type Address, parseAbi } from "viem";
import { type Probe, text } from "../probe.ts";
import { type Level, type SignalId, ratioLevel } from "../signals.ts";
import type { Finding } from "../types.ts";

const chainlinkAbi = parseAbi(["function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)"]);

export interface FeedAge {
  readonly feed: Address;
  readonly updatedAt: bigint;
  readonly heartbeatSeconds: bigint;
  /** M-03 for a collateral leg, M-04 for a debt asset's feed. */
  readonly signal: "M-03" | "M-04";
}

export interface OracleInput {
  readonly now: number;
  /** null: that feed's read failed this round. */
  readonly feeds: ReadonlyMap<string, FeedAge | null>;
}

export const feedSubject = (feed: string) => `feed:${feed.toLowerCase()}`;

/** A leg older than its heartbeat warns, older than 1.5 heartbeats pages; none without a heartbeat. */
export function feedLevel(f: Pick<FeedAge, "updatedAt" | "heartbeatSeconds">, now: number): Level | null {
  if (f.heartbeatSeconds === 0n) return null;
  const age = BigInt(now) > f.updatedAt ? BigInt(now) - f.updatedAt : 0n;
  return ratioLevel(age, f.heartbeatSeconds, [100n, 100n], [150n, 100n], "above");
}

export function oracleProbe(): Probe<OracleInput> {
  return {
    name: "oracle",

    async read(ctx) {
      const legs = new Map<string, { heartbeatSeconds: bigint; signal: FeedAge["signal"] }>();
      for (const d of ctx.manifest.debtReserves) for (const f of d.feeds) legs.set(f.feed.toLowerCase(), { heartbeatSeconds: BigInt(f.heartbeatSeconds), signal: "M-04" });
      for (const m of ctx.manifest.markets) for (const f of m.feeds) legs.set(f.feed.toLowerCase(), { heartbeatSeconds: BigInt(f.heartbeatSeconds), signal: "M-03" });
      const feeds = [...legs.keys()] as Address[];
      const r = await some(ctx.views, feeds.map((feed) => ({ address: feed, abi: chainlinkAbi, functionName: "latestRoundData" })));
      const out = new Map<string, FeedAge | null>();
      feeds.forEach((feed, i) => {
        const round = r[i] as readonly unknown[] | null;
        out.set(feed, round ? { feed, updatedAt: BigInt(round[3] as bigint), ...legs.get(feed)! } : null);
      });
      return { now: ctx.block.timestamp, feeds: out };
    },

    evaluate(input) {
      const out: Finding[] = [];
      for (const [feed, f] of input.feeds) {
        if (!f) {
          out.push({ signal: "M-03" as SignalId, kind: "unread", level: "ok", subject: feedSubject(feed), detail: {} });
          continue;
        }
        const level = feedLevel(f, input.now);
        if (level === null) continue;
        out.push({ signal: f.signal, kind: "condition", level, subject: feedSubject(feed), detail: { feed, ageSeconds: String(Math.max(0, input.now - Number(f.updatedAt))), heartbeatSeconds: f.heartbeatSeconds.toString(10) } });
      }
      return out;
    },

    evidence(input, subject) {
      const f = input.feeds.get(subject.slice("feed:".length));
      return f ? text(f) : null;
    },
  };
}
