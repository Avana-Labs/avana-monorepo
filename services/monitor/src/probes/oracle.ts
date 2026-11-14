// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Oracle signals: M-01 for each DebtOracle (the LPOracle side is in the snapshot), M-02 feed disagreement, M-03 the
// age of every Chainlink leg the manifest lists, M-04 the debt price age, M-05 the USD band distance of markets whose
// tokens are all USD stablecoins (a market without a band has usdBandLow = 0 and is skipped).

import { debtOracleAbi, lensAbi, lpOracleAbi, parameterStoreAbi } from "@avana/protocol/abis";
import { some } from "@avana/services-common/views";
import { type Address, parseAbi } from "viem";
import { type Probe, text } from "../probe.ts";
import { type Level, type SignalId, ratioLevel } from "../signals.ts";
import { PRICE_STATE } from "../rules/snapshot.ts";
import type { Finding } from "../types.ts";

const chainlinkAbi = parseAbi(["function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)"]);

/** One LPOracle's disagreement and band inputs. */
export interface MarketOracle {
  readonly marketId: string;
  readonly name: string;
  readonly lpOracle: Address;
  readonly disagreeSince: bigint;
  readonly disagreementPauseMax: bigint;
  /** 8 decimals; √(q0·q1) for two tokens. */
  readonly usdLevel: bigint;
  readonly usdBandLow: bigint;
}

export interface FeedAge {
  readonly feed: Address;
  readonly updatedAt: bigint;
  readonly feedMaxAge: bigint;
}

export interface DebtPrice {
  readonly spoke: Address;
  readonly reserveId: string;
  readonly state: number;
  readonly age: bigint;
  readonly fixedPrice: boolean;
  readonly borrowPriceMaxAge: bigint;
  readonly liquidationPriceMaxAge: bigint;
}

export interface OracleInput {
  readonly now: number;
  /** null: that subject's reads failed this round. */
  readonly markets: ReadonlyMap<string, MarketOracle | null>;
  readonly feeds: ReadonlyMap<string, FeedAge | null>;
  readonly debts: ReadonlyMap<string, DebtPrice | null>;
}

export const marketSubject = (id: string, what: "disagreement" | "band") => `market:${id}:${what}`;
export const feedSubject = (feed: string) => `feed:${feed.toLowerCase()}`;
export const debtSubject = (spoke: string, reserveId: string, what: "state" | "age") => `debt:${spoke.toLowerCase()}:${reserveId}:${what}`;

const PAGE_LEAD_SECONDS = 1_800n;

/** M-02: a disagreement warns from its start and pages 30 minutes before `disagreementPauseMax` runs out. */
export function m02(m: MarketOracle, now: number): Level {
  if (m.disagreeSince === 0n) return "ok";
  const endsAt = m.disagreeSince + m.disagreementPauseMax;
  return BigInt(now) + PAGE_LEAD_SECONDS >= endsAt ? "page" : "warn";
}

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

/** M-05: the USD level below 0.95 warns, below 0.90 pages (8 decimals); none for a market without a band. */
export function m05(m: MarketOracle): Level | null {
  if (m.usdBandLow === 0n) return null;
  return m.usdLevel < 90_000_000n ? "page" : m.usdLevel < 95_000_000n ? "warn" : "ok";
}

const asBig = (x: unknown) => BigInt(x as bigint | number);

export function oracleProbe(): Probe<OracleInput> {
  return {
    name: "oracle",

    async read(ctx) {
      const store = ctx.manifest.avana.parameterStore.address;
      const lens = ctx.manifest.avana.lens.address;
      const markets = ctx.snapshot.markets;
      const marketCalls = markets.flatMap((m) => [
        { address: m.lpOracle, abi: lpOracleAbi, functionName: "getPriceState" },
        { address: store, abi: parameterStoreAbi, functionName: "getOracleConfig", args: [m.lpOracle] },
      ]);
      const feeds = [...new Set([...ctx.manifest.markets.flatMap((m) => m.feeds), ...ctx.manifest.debtReserves.flatMap((d) => d.feeds)].map((f) => f.feed.toLowerCase() as Address))];
      const feedCalls = feeds.flatMap((feed) => [
        { address: feed, abi: chainlinkAbi, functionName: "latestRoundData" },
        { address: store, abi: parameterStoreAbi, functionName: "getFeed", args: [feed] },
      ]);
      const debts = ctx.manifest.debtReserves.filter((d) => d.debtOracle !== null);
      const debtCalls = debts.flatMap((d) => [
        { address: lens, abi: lensAbi, functionName: "getDebtPriceState", args: [d.spoke, d.debtReserveId] },
        { address: d.debtOracle!.address, abi: debtOracleAbi, functionName: "borrowPriceMaxAge" },
        { address: d.debtOracle!.address, abi: debtOracleAbi, functionName: "liquidationPriceMaxAge" },
      ]);
      const r = await some(ctx.views, [...marketCalls, ...feedCalls, ...debtCalls]);
      let i = 0;

      const marketOut = new Map<string, MarketOracle | null>();
      for (const m of markets) {
        const ps = r[i++] as { usdLevel: bigint; disagreeSince: bigint } | null;
        const cfg = r[i++] as { usdBandLow: bigint; disagreementPauseMax: number } | null;
        marketOut.set(m.marketId, ps && cfg ? { marketId: m.marketId, name: m.name, lpOracle: m.lpOracle, disagreeSince: asBig(ps.disagreeSince), disagreementPauseMax: asBig(cfg.disagreementPauseMax), usdLevel: asBig(ps.usdLevel), usdBandLow: asBig(cfg.usdBandLow) } : null);
      }
      const feedOut = new Map<string, FeedAge | null>();
      for (const feed of feeds) {
        const round = r[i++] as readonly unknown[] | null;
        const cfg = r[i++] as { feedMaxAge: number } | null;
        feedOut.set(feed, round && cfg ? { feed, updatedAt: asBig(round[3]), feedMaxAge: asBig(cfg.feedMaxAge) } : null);
      }
      const debtOut = new Map<string, DebtPrice | null>();
      for (const d of debts) {
        const v = r[i++] as { state: number; age: bigint; fixedPrice: boolean } | null;
        const borrowMax = r[i++];
        const liqMax = r[i++];
        const key = `${d.spoke.toLowerCase()}:${d.debtReserveId}`;
        debtOut.set(key, v && borrowMax !== null && liqMax !== null ? { spoke: d.spoke, reserveId: d.debtReserveId.toString(10), state: Number(v.state), age: asBig(v.age), fixedPrice: v.fixedPrice, borrowPriceMaxAge: asBig(borrowMax), liquidationPriceMaxAge: asBig(liqMax) } : null);
      }
      return { now: ctx.block.timestamp, markets: marketOut, feeds: feedOut, debts: debtOut };
    },

    evaluate(input) {
      const out: Finding[] = [];
      const push = (signal: SignalId, subject: string, level: Level | null, detail: Record<string, string>) => {
        if (level !== null) out.push({ signal, kind: "condition", level, subject, detail });
      };
      const unread = (signal: SignalId, subject: string) => out.push({ signal, kind: "unread", level: "ok", subject, detail: {} });

      for (const [id, m] of input.markets) {
        if (!m) {
          unread("M-02", marketSubject(id, "disagreement"));
          unread("M-05", marketSubject(id, "band"));
          continue;
        }
        push("M-02", marketSubject(id, "disagreement"), m02(m, input.now), { market: m.name, disagreeSince: m.disagreeSince.toString(10), disagreementPauseMax: m.disagreementPauseMax.toString(10) });
        push("M-05", marketSubject(id, "band"), m05(m), { market: m.name, usdLevel8: m.usdLevel.toString(10) });
      }
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
        const state: Level = d.state === 3 ? "page" : d.state === 2 ? "warn" : "ok";
        push("M-01", debtSubject(spoke, reserveId, "state"), state, { debtReserve: reserveId, spoke, priceState: PRICE_STATE[d.state] ?? String(d.state) });
        push("M-04", debtSubject(spoke, reserveId, "age"), m04(d), { debtReserve: reserveId, spoke, ageSeconds: d.age.toString(10), borrowPriceMaxAge: d.borrowPriceMaxAge.toString(10), liquidationPriceMaxAge: d.liquidationPriceMaxAge.toString(10) });
      }
      return out;
    },

    evidence(input, subject) {
      const [kind, a, b] = subject.split(":");
      if (kind === "market") return input.markets.get(a!) ? text(input.markets.get(a!)) : null;
      if (kind === "feed") return input.feeds.get(a!) ? text(input.feeds.get(a!)) : null;
      if (kind === "debt") return input.debts.get(`${a}:${b}`) ? text(input.debts.get(`${a}:${b}`)) : null;
      return null;
    },
  };
}
