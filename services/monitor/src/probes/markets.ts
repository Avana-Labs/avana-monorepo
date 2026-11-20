// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Market price signals, per market of the snapshot:
//   M-36  band edge: a Custom range market's pool price approaching the edge of its band (fixed for life). Within 10 %
//         of the band's width from an edge warns; outside the band pages, since every position the market holds is
//         then out of range and its floor credit sits at the band edge (L × min(r0, r1)).
//   M-37  depeg above 1 % on a Stable or Correlated pair: the pool's price away from the LPOracle's fair price (the
//         Chainlink ratio) by more than 1 %, or, on a Stable pair, a token's Chainlink price below $0.99. The response
//         to a depeg is a freeze of the market's vault-token reserve on its Spoke: the alert pages while the reserve is
//         still open and warns once it is frozen.
// The pool price is the pool's own `slot0` (Uniswap v3, Slipstream) or the PoolManager's slot0 of the PoolId (Uniswap v4).

import { uniswapV4PoolManager } from "@avana/services-common";
import { type ContractCall, type MarketRow, some } from "@avana/services-common/views";
import { type Address, type Hex, encodeAbiParameters, keccak256, parseAbi } from "viem";
import { type Probe, text } from "../probe.ts";
import type { Level } from "../signals.ts";
import type { Finding } from "../types.ts";

const riskModuleAbi = parseAbi(["function getSpoke(address spoke) view returns ((address hub, uint8 kind) config)"]);
const lpOracleAbi = parseAbi(["function getPrices() view returns (uint256 price0, uint256 price1, uint160 sqrtPriceX96)"]);
/** The first two words of `slot0`, the same in Uniswap v3 and Slipstream pools. */
const slot0Abi = parseAbi(["function slot0() view returns (uint160 sqrtPriceX96, int24 tick)"]);
const extsloadAbi = parseAbi(["function extsload(bytes32 slot) view returns (bytes32)"]);

/** `IRiskModule.SpokeKind`. */
export const SPOKE_KIND = ["None", "Stable", "Correlated", "Volatile"] as const;

/** Uniswap v4 StateLibrary: the pools mapping is at slot 6; slot0 is the pool state's first word. */
export function v4Slot0Slot(poolId: Hex): Hex {
  return keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [poolId, 6n]));
}

/** sqrtPriceX96 (low 160 bits) and tick (the next 24 bits, signed) of a packed v4 slot0. */
export function decodeV4Slot0(word: Hex): { sqrtPriceX96: bigint; tick: number } {
  const v = BigInt(word);
  const raw = Number((v >> 160n) & 0xffffffn);
  return { sqrtPriceX96: v & ((1n << 160n) - 1n), tick: raw >= 0x800000 ? raw - 0x1000000 : raw };
}

export interface MarketPrice {
  readonly name: string;
  readonly kind: MarketRow["kind"];
  readonly spokeKind: (typeof SPOKE_KIND)[number];
  readonly bandLower: number;
  readonly bandUpper: number;
  readonly frozen: boolean;
  readonly tick: number;
  readonly poolSqrtPriceX96: bigint;
  readonly fairSqrtPriceX96: bigint;
  readonly price0: bigint;
  readonly price1: bigint;
}

export interface MarketsInput {
  /** null: a read of that market failed this round. */
  readonly markets: ReadonlyMap<string, MarketPrice | null>;
}

/** M-36: the distance to the nearer band edge in bps of the band's width; negative outside the band. */
export function bandEdgeBps(tick: number, lower: number, upper: number): number {
  const width = upper - lower;
  if (width <= 0) return 0;
  return Math.floor((Math.min(tick - lower, upper - tick) * 10_000) / width);
}

/** M-36 level: outside the band pages, within 10 % of its width from an edge warns. */
export function m36(edgeBps: number): Level {
  return edgeBps < 0 ? "page" : edgeBps <= 1_000 ? "warn" : "ok";
}

/** |pool price / fair price − 1| in parts per million, from the two square-root prices. */
export function deviationPpm(poolSqrt: bigint, fairSqrt: bigint): bigint {
  if (fairSqrt === 0n) return 0n;
  const ratio = (poolSqrt * poolSqrt * 1_000_000n) / (fairSqrt * fairSqrt);
  return ratio > 1_000_000n ? ratio - 1_000_000n : 1_000_000n - ratio;
}

/** The depeg measures of a Stable or Correlated market; null for another kind. */
export function depeg(m: MarketPrice): { ppm: bigint; lowToken: 0 | 1 | null } | null {
  if (m.spokeKind !== "Stable" && m.spokeKind !== "Correlated") return null;
  const floor = 99_000_000n; // $0.99 at 8 decimals
  const lowToken = m.spokeKind !== "Stable" ? null : m.price0 < floor ? 0 : m.price1 < floor ? 1 : null;
  return { ppm: deviationPpm(m.poolSqrtPriceX96, m.fairSqrtPriceX96), lowToken };
}

/** M-37 level: a depeg above 1 % pages while the market is open and warns once it is frozen (depeg = freeze). */
export function m37(d: { ppm: bigint; lowToken: 0 | 1 | null }, frozen: boolean): Level {
  const depegged = d.ppm > 10_000n || d.lowToken !== null;
  if (!depegged) return "ok";
  return frozen ? "warn" : "page";
}

export function marketsProbe(): Probe<MarketsInput> {
  return {
    name: "markets",

    async read(ctx) {
      const m = ctx.manifest;
      const v4 = new Set(m.avana.integrations.filter((x) => x.kind === "uniswap-v4").map((x) => x.integrationId));
      const rmOf = new Map(m.avana.integrations.map((x) => [x.integrationId, x.riskModule.address]));
      const manager = uniswapV4PoolManager(m);
      const markets = ctx.snapshot.markets;
      const calls = markets.flatMap((mk): (ContractCall | null)[] => [
        { address: rmOf.get(mk.integrationId)!, abi: riskModuleAbi, functionName: "getSpoke", args: [mk.spoke] },
        { address: mk.lpOracle, abi: lpOracleAbi, functionName: "getPrices" },
        v4.has(mk.integrationId)
          ? manager
            ? { address: manager.address, abi: extsloadAbi, functionName: "extsload", args: [v4Slot0Slot(mk.pool)] }
            : null
          : { address: `0x${mk.pool.slice(-40)}` as Address, abi: slot0Abi, functionName: "slot0" },
      ]);
      const r = await some(ctx.views, calls.filter((c): c is ContractCall => c !== null));
      let i = 0;
      const out = new Map<string, MarketPrice | null>();
      markets.forEach((mk, k) => {
        const spoke = r[i++] as { kind: number } | null;
        const prices = r[i++] as readonly [bigint, bigint, bigint] | null;
        const poolCall = calls[k * 3 + 2];
        const pool = poolCall === null ? null : r[i++];
        if (!spoke || !prices || pool === null || pool === undefined) {
          out.set(mk.marketId, null);
          return;
        }
        const slot0 = poolCall!.functionName === "extsload" ? decodeV4Slot0(pool as Hex) : { sqrtPriceX96: (pool as readonly [bigint, number])[0], tick: Number((pool as readonly [bigint, number])[1]) };
        out.set(mk.marketId, {
          name: mk.name,
          kind: mk.kind,
          spokeKind: SPOKE_KIND[spoke.kind] ?? "None",
          bandLower: mk.bandLower,
          bandUpper: mk.bandUpper,
          frozen: mk.frozen,
          tick: slot0.tick,
          poolSqrtPriceX96: slot0.sqrtPriceX96,
          fairSqrtPriceX96: BigInt(prices[2]),
          price0: BigInt(prices[0]),
          price1: BigInt(prices[1]),
        });
      });
      return { markets: out };
    },

    evaluate(input) {
      const out: Finding[] = [];
      for (const [id, mk] of input.markets) {
        if (!mk) {
          out.push({ signal: "M-36", kind: "unread", level: "ok", subject: `market:${id}:band`, detail: {} });
          out.push({ signal: "M-37", kind: "unread", level: "ok", subject: `market:${id}:depeg`, detail: {} });
          continue;
        }
        if (mk.kind === "custom-range") {
          const edge = bandEdgeBps(mk.tick, mk.bandLower, mk.bandUpper);
          out.push({
            signal: "M-36",
            kind: "condition",
            level: m36(edge),
            subject: `market:${id}:band`,
            detail: { market: mk.name, tick: String(mk.tick), bandLower: String(mk.bandLower), bandUpper: String(mk.bandUpper), edgeDistanceBps: String(edge) },
          });
        }
        const d = depeg(mk);
        if (d === null) continue;
        const level = m37(d, mk.frozen);
        out.push({
          signal: "M-37",
          kind: "condition",
          level,
          subject: `market:${id}:depeg`,
          detail: {
            market: mk.name,
            pair: mk.spokeKind,
            poolVsOracleBps: (d.ppm / 100n).toString(10),
            ...(d.lowToken !== null ? { tokenBelowPeg: `token${d.lowToken}` } : {}),
            reserve: mk.frozen ? "frozen" : "open",
            response: level === "ok" ? "none" : mk.frozen ? "frozen: the depeg response is in place" : "freeze the market's vault-token reserve on its Spoke (depeg = freeze)",
          },
        });
      }
      return out;
    },

    evidence(input, subject) {
      const id = subject.split(":")[1]!;
      return input.markets.get(id) ? text(input.markets.get(id)) : null;
    },
  };
}
