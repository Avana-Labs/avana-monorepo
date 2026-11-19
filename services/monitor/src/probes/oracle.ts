// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Oracle signals: M-01 for each non-GHO debt reserve's price (the LPOracle side is in the snapshot), M-03 the age of
// every Chainlink leg the manifest lists, M-04 the debt price age against its feed's ParameterStore ages. M-02 is retired: the stateless LPOracle records no disagreement.

import { lensAbi, parameterStoreAbi } from "@avana/protocol/abis";
import { some } from "@avana/services-common/views";
import { type Address, parseAbi } from "viem";
import { type Probe, text } from "../probe.ts";
import { type Level, type SignalId, ratioLevel } from "../signals.ts";
import { PRICE_STATE } from "../rules/snapshot.ts";
import type { Finding } from "../types.ts";

const chainlinkAbi = parseAbi(["function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)"]);

export interface FeedAge {
  readonly feed: Address;
  readonly updatedAt: bigint;
  readonly feedMaxAge: bigint;
}

export interface DebtPrice {
  readonly spoke: Address;
  readonly reserveId: string;
  /** The reserve's Aave price source (Lens `source`): the asset's Chainlink USD feed. */
  readonly source: Address;
  readonly state: number;
  readonly age: bigint;
  readonly fixedPrice: boolean;
  /** The source feed's ParameterStore ages; 0 for a fixed price. */
  readonly borrowPriceMaxAge: bigint;
  readonly liquidationPriceMaxAge: bigint;
}

export interface OracleInput {
  readonly now: number;
  /** null: that subject's reads failed this round. */
  readonly feeds: ReadonlyMap<string, FeedAge | null>;
  readonly debts: ReadonlyMap<string, DebtPrice | null>;
}

export const feedSubject = (feed: string) => `feed:${feed.toLowerCase()}`;
export const debtSubject = (spoke: string, reserveId: string, what: "state" | "age") => `debt:${spoke.toLowerCase()}:${reserveId}:${what}`;

/** M-03: a leg older than 50 % of `feedMaxAge` warns, older than 90 % pages; none without a configured maximum. */
export function m03(f: FeedAge, now: number): Level | null {
  if (f.feedMaxAge === 0n) return null;
  const age = BigInt(now) > f.updatedAt ? BigInt(now) - f.updatedAt : 0n;
  return ratioLevel(age, f.feedMaxAge, [50n, 100n], [90n, 100n], "above");
}

/** M-04: older than `borrowPriceMaxAge` warns, older than 90 % of `liquidationPriceMaxAge` pages; GHO's fixed price never. */
export function m04(d: DebtPrice): Level | null {
  if (d.fixedPrice) return null;
  if (d.liquidationPriceMaxAge > 0n && d.age * 10n > d.liquidationPriceMaxAge * 9n) return "page";
  return d.age > d.borrowPriceMaxAge ? "warn" : "ok";
}

const asBig = (x: unknown) => BigInt(x as bigint | number);

export function oracleProbe(): Probe<OracleInput> {
  return {
    name: "oracle",

    async read(ctx) {
      const store = ctx.manifest.avana.parameterStore.address;
      const lens = ctx.manifest.avana.lens.address;
      const feeds = [...new Set([...ctx.manifest.markets.flatMap((m) => m.feeds), ...ctx.manifest.debtReserves.flatMap((d) => d.feeds)].map((f) => f.feed.toLowerCase() as Address))];
      const feedCalls = feeds.flatMap((feed) => [
        { address: feed, abi: chainlinkAbi, functionName: "latestRoundData" },
        { address: store, abi: parameterStoreAbi, functionName: "getFeed", args: [feed] },
      ]);
      // A non-GHO debt reserve's price is its asset's Chainlink feed, which the Lens names as `source`; its age limits
      // are that feed's ParameterStore ages, read once the source is known.
      const debts = ctx.manifest.debtReserves.filter((d) => !d.isGho);
      const debtCalls = debts.map((d) => ({ address: lens, abi: lensAbi, functionName: "getDebtPriceState", args: [d.spoke, d.debtReserveId] }));
      const r = await some(ctx.views, [...feedCalls, ...debtCalls]);
      let i = 0;

      const feedOut = new Map<string, FeedAge | null>();
      for (const feed of feeds) {
        const round = r[i++] as readonly unknown[] | null;
        const cfg = r[i++] as { feedMaxAge: number } | null;
        feedOut.set(feed, round && cfg ? { feed, updatedAt: asBig(round[3]), feedMaxAge: asBig(cfg.feedMaxAge) } : null);
      }
      const views = debts.map(() => r[i++] as { source: Address; state: number; age: bigint; fixedPrice: boolean } | null);
      const priced = views.filter((v): v is NonNullable<typeof v> => v !== null && !v.fixedPrice);
      const ages = await some(ctx.views, priced.flatMap((v) => [
        { address: store, abi: parameterStoreAbi, functionName: "borrowPriceMaxAge", args: [v.source] },
        { address: store, abi: parameterStoreAbi, functionName: "liquidationPriceMaxAge", args: [v.source] },
      ]));
      let j = 0;
      const debtOut = new Map<string, DebtPrice | null>();
      for (const [k, d] of debts.entries()) {
        const v = views[k];
        const key = `${d.spoke.toLowerCase()}:${d.debtReserveId}`;
        if (!v) {
          debtOut.set(key, null);
          continue;
        }
        const [borrowMax, liqMax] = v.fixedPrice ? [0, 0] : [ages[j++], ages[j++]];
        debtOut.set(
          key,
          borrowMax !== null && borrowMax !== undefined && liqMax !== null && liqMax !== undefined
            ? { spoke: d.spoke, reserveId: d.debtReserveId.toString(10), source: v.source, state: Number(v.state), age: asBig(v.age), fixedPrice: v.fixedPrice, borrowPriceMaxAge: asBig(borrowMax), liquidationPriceMaxAge: asBig(liqMax) }
            : null,
        );
      }
      return { now: ctx.block.timestamp, feeds: feedOut, debts: debtOut };
    },

    evaluate(input) {
      const out: Finding[] = [];
      const push = (signal: SignalId, subject: string, level: Level | null, detail: Record<string, string>) => {
        if (level !== null) out.push({ signal, kind: "condition", level, subject, detail });
      };
      const unread = (signal: SignalId, subject: string) => out.push({ signal, kind: "unread", level: "ok", subject, detail: {} });

      for (const [feed, f] of input.feeds) {
        if (!f) {
          unread("M-03", feedSubject(feed));
          continue;
        }
        push("M-03", feedSubject(feed), m03(f, input.now), { feed, ageSeconds: String(Math.max(0, input.now - Number(f.updatedAt))), feedMaxAge: f.feedMaxAge.toString(10) });
      }
      for (const [key, d] of input.debts) {
        const [spoke, reserveId] = key.split(":") as [string, string];
        if (!d) {
          unread("M-01", debtSubject(spoke, reserveId, "state"));
          unread("M-04", debtSubject(spoke, reserveId, "age"));
          continue;
        }
        // The Lens reports a debt price Live while its feed is within liquidationPriceMaxAge, else Cached.
        const state: Level = d.state === 3 ? "page" : d.state === 2 ? "warn" : "ok";
        push("M-01", debtSubject(spoke, reserveId, "state"), state, { debtReserve: reserveId, spoke, priceState: PRICE_STATE[d.state] ?? String(d.state) });
        push("M-04", debtSubject(spoke, reserveId, "age"), m04(d), { debtReserve: reserveId, spoke, feed: d.source, ageSeconds: d.age.toString(10), borrowPriceMaxAge: d.borrowPriceMaxAge.toString(10), liquidationPriceMaxAge: d.liquidationPriceMaxAge.toString(10) });
      }
      return out;
    },

    evidence(input, subject) {
      const [kind, a, b] = subject.split(":");
      if (kind === "feed") return input.feeds.get(a!) ? text(input.feeds.get(a!)) : null;
      if (kind === "debt") return input.debts.get(`${a}:${b}`) ? text(input.debts.get(`${a}:${b}`)) : null;
      return null;
    },
  };
}
