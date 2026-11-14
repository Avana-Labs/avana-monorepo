// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Loss-layer, backing and pool signals: M-07 Avana's live share of each pool, M-13 the First-Loss Reserve and DAO
// deficit offset balances against their minimums, M-14 the tail coverage ratio, M-21 the Lens backing check of each
// market, and M-28 liquidity leaving each listed pool (the pool's in-range liquidity, judged over the hour).

import { lensAbi } from "@avana/protocol/abis";
import { ZERO, some } from "@avana/services-common/views";
import { type Address, parseAbi } from "viem";
import { History } from "../history.ts";
import { type Probe, text } from "../probe.ts";
import { type Level, type SignalId, ratioLevel } from "../signals.ts";
import { dropLevel } from "../rules/snapshot.ts";
import type { Finding } from "../types.ts";

const poolAbi = parseAbi(["function liquidity() view returns (uint128)"]);
const minimumAbi = parseAbi(["function firstLossReserveMinimum() view returns (uint256)"]);

/** The invariants `Lens.checkBacking` reports; each must hold. */
export const BACKING_FLAGS = ["supplyEqualsCredited", "hubHoldsSupplied", "sharesEqualAssets", "noDrawnShares", "noDrawCap", "singleBorrowSpoke", "noLiquidityFee", "noReinvestment", "reserveFlags"] as const;

export interface MarketCoverage {
  readonly name: string;
  readonly poolShareBps: bigint;
  readonly poolShareMaxBps: bigint;
  /** The backing flags that do not hold; empty when the market is backed. */
  readonly backingBroken: readonly string[];
}

export interface Tail {
  readonly hub: Address;
  readonly asset: Address;
  readonly funded: bigint;
  readonly minimum: bigint;
  readonly ratioBps: bigint;
  readonly deficitOffset: Address;
  readonly offsetFunded: bigint;
  /** The offset's `firstLossReserveMinimum` (its daoDeficitOffset); null without an offset. */
  readonly offsetMinimum: bigint | null;
}

export interface CoverageInput {
  readonly now: number;
  readonly markets: ReadonlyMap<string, MarketCoverage | null>;
  readonly tails: ReadonlyMap<string, Tail | null>;
  readonly pools: ReadonlyMap<string, bigint | null>;
}

export const tailKey = (hub: string, asset: string) => `${hub.toLowerCase()}:${asset.toLowerCase()}`;

/** M-07: above 75 % of the pool-share breaker level warns (15 % at the default 20 %), above it pages. */
export function m07(m: MarketCoverage): Level | null {
  if (m.poolShareMaxBps === 0n) return null;
  return ratioLevel(m.poolShareBps, m.poolShareMaxBps, [75n, 100n], [100n, 100n], "above");
}

/** M-13, First-Loss Reserve: below 150 % of its minimum warns, below 100 % pages; none without a minimum. */
export function m13Reserve(t: Tail): Level | null {
  if (t.minimum === 0n) return null;
  return ratioLevel(t.funded, t.minimum, [150n, 100n], [100n, 100n], "below");
}

/** M-13, DAO deficit offset: below its daoDeficitOffset warns (a monitoring alert only, Q-399). */
export function m13Offset(t: Tail): Level | null {
  if (t.offsetMinimum === null || t.offsetMinimum === 0n) return null;
  return t.offsetFunded < t.offsetMinimum ? "warn" : "ok";
}

/** M-14: the tail coverage ratio below 150 % warns, below 100 % pages. */
export function m14(t: Tail): Level {
  return t.ratioBps < 10_000n ? "page" : t.ratioBps < 15_000n ? "warn" : "ok";
}

const asBig = (x: unknown) => BigInt(x as bigint | number);

export function coverageProbe(): Probe<CoverageInput> {
  const history = new History(3_600);
  return {
    name: "coverage",

    async read(ctx) {
      const lens = ctx.manifest.avana.lens.address;
      const markets = ctx.snapshot.markets;
      const tails = ctx.snapshot.hubAssets.filter((a) => a.exposure !== null && a.exposure.firstLossReserve !== ZERO).map((a) => ({ hub: a.hub, asset: a.underlying }));
      const pools = [...new Set(markets.map((m) => m.pool.toLowerCase() as Address))];
      const r = await some(ctx.views, [
        ...markets.flatMap((m) => [
          { address: lens, abi: lensAbi, functionName: "getCapHeadroom", args: [m.vaultToken, ZERO] },
          { address: lens, abi: lensAbi, functionName: "checkBacking", args: [m.vaultToken] },
        ]),
        ...tails.map((t) => ({ address: lens, abi: lensAbi, functionName: "getTailCoverage", args: [t.hub, t.asset] })),
        ...pools.map((p) => ({ address: p, abi: poolAbi, functionName: "liquidity" })),
      ]);
      let i = 0;
      const marketOut = new Map<string, MarketCoverage | null>();
      for (const m of markets) {
        const caps = r[i++] as { poolShareBps: bigint; poolShareMaxBps: bigint } | null;
        const backing = r[i++] as Record<string, unknown> | null;
        marketOut.set(m.marketId, caps && backing ? { name: m.name, poolShareBps: asBig(caps.poolShareBps), poolShareMaxBps: asBig(caps.poolShareMaxBps), backingBroken: BACKING_FLAGS.filter((k) => backing[k] !== true) } : null);
      }
      const tailRows = tails.map((t) => ({ t, c: r[i++] as { funded: bigint; minimum: bigint; ratioBps: bigint; deficitOffset: Address; offsetFunded: bigint } | null }));
      const poolOut = new Map<string, bigint | null>();
      for (const p of pools) {
        const l = r[i++];
        poolOut.set(p, l === null ? null : asBig(l));
      }
      // The offsets' minimums, once the coverage reads name them.
      const offsets = tailRows.filter((x) => x.c && x.c.deficitOffset !== ZERO).map((x) => x.c!.deficitOffset);
      const mins = await some(ctx.views, offsets.map((o) => ({ address: o, abi: minimumAbi, functionName: "firstLossReserveMinimum" })));
      const minOf = new Map(offsets.map((o, k) => [o.toLowerCase(), mins[k]]));
      const tailOut = new Map<string, Tail | null>();
      for (const { t, c } of tailRows) {
        const offsetMin = c && c.deficitOffset !== ZERO ? minOf.get(c.deficitOffset.toLowerCase()) : null;
        tailOut.set(tailKey(t.hub, t.asset), c && offsetMin !== undefined ? { hub: t.hub, asset: t.asset, funded: asBig(c.funded), minimum: asBig(c.minimum), ratioBps: asBig(c.ratioBps), deficitOffset: c.deficitOffset, offsetFunded: asBig(c.offsetFunded), offsetMinimum: offsetMin === null ? null : asBig(offsetMin) } : null);
      }
      return { now: ctx.block.timestamp, markets: marketOut, tails: tailOut, pools: poolOut };
    },

    evaluate(input) {
      const out: Finding[] = [];
      const push = (signal: SignalId, subject: string, level: Level | null, detail: Record<string, string>) => {
        if (level !== null) out.push({ signal, kind: "condition", level, subject, detail });
      };
      const unread = (signal: SignalId, subject: string) => out.push({ signal, kind: "unread", level: "ok", subject, detail: {} });

      for (const [id, m] of input.markets) {
        if (!m) {
          unread("M-07", `market:${id}:poolShare`);
          unread("M-21", `market:${id}:backing`);
          continue;
        }
        push("M-07", `market:${id}:poolShare`, m07(m), { market: m.name, poolShareBps: m.poolShareBps.toString(10), poolShareMaxBps: m.poolShareMaxBps.toString(10) });
        push("M-21", `market:${id}:backing`, m.backingBroken.length > 0 ? "page" : "ok", { market: m.name, ...(m.backingBroken.length > 0 ? { broken: m.backingBroken.join(",") } : {}) });
      }
      for (const [key, t] of input.tails) {
        const subject = (what: string) => `tail:${key}:${what}`;
        if (!t) {
          for (const [s, w] of [["M-13", "reserve"], ["M-13", "offset"], ["M-14", "ratio"]] as const) unread(s, subject(w));
          continue;
        }
        push("M-13", subject("reserve"), m13Reserve(t), { funded: t.funded.toString(10), minimum: t.minimum.toString(10) });
        push("M-13", subject("offset"), m13Offset(t), { deficitOffset: t.deficitOffset, offsetFunded: t.offsetFunded.toString(10), daoDeficitOffset: String(t.offsetMinimum) });
        push("M-14", subject("ratio"), m14(t), { ratioBps: t.ratioBps.toString(10) });
      }
      const seen = new Set<string>();
      for (const [pool, liquidity] of input.pools) {
        const subject = `pool:${pool}`;
        if (liquidity === null) {
          unread("M-28", subject);
          continue;
        }
        seen.add(subject);
        history.record(subject, input.now, liquidity);
        const drop = history.dropBps(subject);
        push("M-28", subject, dropLevel(drop, 2_000n, 4_000n), { pool, liquidity: liquidity.toString(10), dropBps: drop.toString(10) });
      }
      for (const [pool, l] of input.pools) if (l === null) seen.add(`pool:${pool}`);
      history.retain(seen);
      return out;
    },

    evidence(input, subject) {
      const [kind, a, b] = subject.split(":");
      if (kind === "market") return input.markets.get(a!) ? text(input.markets.get(a!)) : null;
      if (kind === "tail") return input.tails.get(`${a}:${b}`) ? text(input.tails.get(`${a}:${b}`)) : null;
      if (kind === "pool") return input.pools.get(a!) != null ? text(input.pools.get(a!)) : null;
      return null;
    },
  };
}
