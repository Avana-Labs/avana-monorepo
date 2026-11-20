// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Loss-layer and pool signals: M-13 each First-Loss Reserve's and DAO deficit offset's funded balance against its
// minimum, M-14 the draw-cap coverage of each covered Hub asset (the First-Loss Reserve's balance against the balance
// the RiskModules require for the CDP Spokes' draw caps), and M-28 liquidity leaving each listed pool (the pool's
// in-range liquidity, judged over the hour). A pool of a Uniswap v4 integration (its key a PoolId) is read through the
// manifest's PoolManager; it is unread when the manifest names no PoolManager.

import { uniswapV4PoolManager } from "@avana/services-common";
import { type ContractCall, some } from "@avana/services-common/views";
import { type Address, type Hex, encodeAbiParameters, keccak256, parseAbi, toHex } from "viem";
import { History } from "../history.ts";
import { type Probe, text } from "../probe.ts";
import { type Level, type SignalId, ratioLevel } from "../signals.ts";
import { dropLevel } from "../rules/snapshot.ts";
import type { Finding } from "../types.ts";

const poolAbi = parseAbi(["function liquidity() view returns (uint128)"]);
const extsloadAbi = parseAbi(["function extsload(bytes32 slot) view returns (bytes32)"]);
const UINT128 = (1n << 128n) - 1n;

/** Uniswap v4 StateLibrary: pools mapping at slot 6, liquidity in the low 128 bits of the pool state's fourth word. */
export function v4LiquiditySlot(poolId: Hex): Hex {
  const state = BigInt(keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [poolId, 6n])));
  return toHex(state + 3n, { size: 32 });
}
const layerAbi = parseAbi(["function fundedBalance() view returns (uint256)", "function minimum() view returns (uint256)"]);

/** A loss layer's funded balance and minimum. */
export interface Layer {
  readonly address: Address;
  readonly label: string;
  readonly funded: bigint;
  readonly minimum: bigint;
  readonly offset: boolean;
}

/** One covered Hub asset's draw-cap coverage, from the snapshot. */
export interface Coverage {
  readonly funded: bigint;
  readonly required: bigint;
}

export interface CoverageInput {
  readonly now: number;
  readonly layers: ReadonlyMap<string, Layer | null>;
  readonly coverage: ReadonlyMap<string, Coverage>;
  readonly pools: ReadonlyMap<string, bigint | null>;
}

/** M-13: a First-Loss Reserve below 150 % of its minimum warns, below 100 % pages; a DAO deficit offset below its minimum warns. */
export function m13(l: Layer): Level | null {
  if (l.minimum === 0n) return null;
  if (l.offset) return l.funded < l.minimum ? "warn" : "ok";
  return ratioLevel(l.funded, l.minimum, [150n, 100n], [100n, 100n], "below");
}

/** M-14: the funded balance below 150 % of what the draw caps require warns, below 100 % pages (borrowing then stops). */
export function m14(c: Coverage): Level {
  if (c.required === 0n) return "ok";
  return ratioLevel(c.funded, c.required, [150n, 100n], [100n, 100n], "below");
}

const asBig = (x: unknown) => BigInt(x as bigint | number);

export function coverageProbe(): Probe<CoverageInput> {
  const history = new History(3_600);
  return {
    name: "coverage",

    async read(ctx) {
      const m = ctx.manifest;
      const layers = [
        ...m.coverage.firstLossReserves.map((l) => ({ address: l.address, label: `${l.hubLabel} ${l.symbol}`, offset: false })),
        ...m.coverage.daoDeficitOffsets.map((l) => ({ address: l.address, label: `${l.hubLabel} ${l.symbol} DAO offset`, offset: true })),
      ];
      // One read per pool: `liquidity()` on a concentrated-liquidity pool, the PoolManager's storage for a v4 PoolId.
      const v4 = new Set(m.avana.integrations.filter((x) => x.kind === "uniswap-v4").map((x) => x.integrationId));
      const manager = uniswapV4PoolManager(m);
      const poolReads = new Map<string, ContractCall | null>();
      for (const mk of ctx.snapshot.markets) {
        const key = mk.pool.toLowerCase();
        if (poolReads.has(key)) continue;
        if (!v4.has(mk.integrationId)) poolReads.set(key, { address: `0x${key.slice(-40)}` as Address, abi: poolAbi, functionName: "liquidity" });
        else poolReads.set(key, manager ? { address: manager.address, abi: extsloadAbi, functionName: "extsload", args: [v4LiquiditySlot(key as Hex)] } : null);
      }
      const pools = [...poolReads.keys()];
      const r = await some(ctx.views, [
        ...layers.flatMap((l): ContractCall[] => [
          { address: l.address, abi: layerAbi, functionName: "fundedBalance" },
          { address: l.address, abi: layerAbi, functionName: "minimum" },
        ]),
        ...[...poolReads.values()].filter((c): c is ContractCall => c !== null),
      ]);
      let i = 0;
      const layerOut = new Map<string, Layer | null>();
      for (const l of layers) {
        const funded = r[i++];
        const minimum = r[i++];
        layerOut.set(l.address.toLowerCase(), funded === null || minimum === null ? null : { ...l, funded: asBig(funded), minimum: asBig(minimum) });
      }
      const poolOut = new Map<string, bigint | null>();
      for (const p of pools) {
        const call = poolReads.get(p)!;
        const l = call === null ? null : r[i++];
        poolOut.set(p, l === null ? null : call!.functionName === "extsload" ? BigInt(l as Hex) & UINT128 : asBig(l));
      }
      const coverage = new Map(
        ctx.snapshot.hubAssets.filter((a) => a.exposure !== null).map((a) => [`${a.hub}:${a.underlying}`, { funded: BigInt(a.exposure!.fundedBalance), required: BigInt(a.exposure!.required) }]),
      );
      return { now: ctx.block.timestamp, layers: layerOut, coverage, pools: poolOut };
    },

    evaluate(input) {
      const out: Finding[] = [];
      const push = (signal: SignalId, subject: string, level: Level | null, detail: Record<string, string>) => {
        if (level !== null) out.push({ signal, kind: "condition", level, subject, detail });
      };
      for (const [address, l] of input.layers) {
        if (!l) {
          out.push({ signal: "M-13", kind: "unread", level: "ok", subject: `layer:${address}`, detail: {} });
          continue;
        }
        push("M-13", `layer:${address}`, m13(l), { layer: l.label, funded: l.funded.toString(10), minimum: l.minimum.toString(10) });
      }
      for (const [key, c] of input.coverage) {
        push("M-14", `coverage:${key}`, m14(c), { funded: c.funded.toString(10), required: c.required.toString(10) });
      }
      const seen = new Set<string>();
      for (const [pool, liquidity] of input.pools) {
        const subject = `pool:${pool}`;
        seen.add(subject);
        if (liquidity === null) {
          out.push({ signal: "M-28", kind: "unread", level: "ok", subject, detail: {} });
          continue;
        }
        history.record(subject, input.now, liquidity);
        const drop = history.dropBps(subject);
        push("M-28", subject, dropLevel(drop, 2_000n, 4_000n), { pool, liquidity: liquidity.toString(10), dropBps: drop.toString(10) });
      }
      history.retain(seen);
      return out;
    },

    save: () => history.save(),
    restore: (s) => history.restore(s as Map<string, { t: number; v: bigint }[]>),

    evidence(input, subject) {
      const [kind, a, b] = subject.split(":");
      if (kind === "layer") return input.layers.get(a!) ? text(input.layers.get(a!)) : null;
      if (kind === "coverage") return input.coverage.get(`${a}:${b}`) ? text(input.coverage.get(`${a}:${b}`)) : null;
      if (kind === "pool") return input.pools.get(a!) != null ? text(input.pools.get(a!)) : null;
      return null;
    },
  };
}
