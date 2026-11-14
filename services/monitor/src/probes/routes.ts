// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// M-11 route depth at stress size and M-12 GSM exposure headroom, measured once a day (MONITOR_ROUTE_CHECK_HOURS) at
// the latest block. For every route slot (market, pool token, debt asset, primary or backup) the route's swap is
// simulated (sim.ts) from the pool token into the debt asset at 120 % and 100 % of the slot's routeDepthThreshold
// (base units of the debt asset, the stress size published at listing, REQ-ROUTE-006), converted into the pool token at
// the oracle prices. A swap counts when it returns at least the stress value less the market's slippage allowance.
// Absorbing 120 % is ok, only 100 % warns, less pages; a slot with no threshold set warns. For a GSM route the GSM's
// exposure room (cap less the underlying it holds) below 2× the stress input warns and below 1× pages.
// Between measurements the last findings are reported again, so they stay open; the confirming read on the second
// provider at the measurement's block simulates again there.

import { lpOracleAbi, marketRegistryAbi, parameterStoreAbi } from "@avana/protocol/abis";
import { ZERO, some } from "@avana/services-common/views";
import { type Address, parseAbi } from "viem";
import { type Probe, text } from "../probe.ts";
import { type TokenSlots, findSlots, simulateSwap } from "../sim.ts";
import type { Level } from "../signals.ts";
import type { Finding } from "../types.ts";

const routeViews = parseAbi(["function routeType() view returns (uint8)", "function dependencies() view returns (address[])"]);
const gsmViews = parseAbi(["function getExposureCap() view returns (uint128)", "function getAvailableUnderlyingLiquidity() view returns (uint256)"]);

export interface SlotResult {
  readonly marketId: string;
  readonly token: Address;
  readonly debtAsset: Address;
  readonly kind: number;
  readonly route: Address;
  readonly threshold: bigint;
  /** Input at 100 % of the stress size, base units of the pool token. */
  readonly stressIn: bigint;
  /** Minimum acceptable output at 100 %, base units of the debt asset. */
  readonly minOut100: bigint;
  /** Outputs at 120 % and 100 %, or the revert. */
  readonly at120: string;
  readonly at100: string;
  readonly depth: "120" | "100" | "below" | "noThreshold" | "notSimulated";
  /** For a GSM route: exposure cap less underlying held, base units of the underlying; null otherwise. */
  readonly gsmRoom: bigint | null;
}

export interface RoutesInput {
  readonly measuredAt: number;
  readonly block: bigint;
  readonly slots: ReadonlyMap<string, SlotResult | null>;
}

export const slotKey = (marketId: string, token: string, debtAsset: string, kind: number) => `${marketId}:${token.toLowerCase()}:${debtAsset.toLowerCase()}:${kind}`;

/** M-11 from a measured slot. */
export function m11(s: SlotResult): Level {
  return s.depth === "120" ? "ok" : s.depth === "100" || s.depth === "noThreshold" || s.depth === "notSimulated" ? "warn" : "page";
}

/** M-12: GSM room below 2× the stress input warns, below 1× pages. */
export function m12(room: bigint, stressIn: bigint): Level {
  return room < stressIn ? "page" : room < 2n * stressIn ? "warn" : "ok";
}

const asBig = (x: unknown) => BigInt(x as bigint | number);

export function routesProbe(intervalSeconds = 86_400): Probe<RoutesInput> {
  let last: RoutesInput | null = null;
  const slotsOf = new Map<string, TokenSlots | null>();

  async function measure(ctx: Parameters<Probe<RoutesInput>["read"]>[0]): Promise<RoutesInput> {
    const m = ctx.manifest;
    const lps = m.avana.lpVaultSwap.address;
    const lock = m.avana.lock.address;
    const registry = m.avana.marketRegistry.address;
    const store = m.avana.parameterStore.address;
    const markets = ctx.snapshot.markets.filter((x) => x.status === 2 || x.status === 3);
    const pre = await some(ctx.views, markets.flatMap((x) => [
      { address: x.lpOracle, abi: lpOracleAbi, functionName: "getTokenPrices" },
      { address: store, abi: parameterStoreAbi, functionName: "getMarketParams", args: [BigInt(x.marketId)] },
    ]));
    type Plan = { marketId: string; token: Address; tokenDecimals: number; tokenPrice: bigint; debt: { asset: Address; decimals: number; price: bigint }; kind: number; slippageBps: bigint };
    const plans: Plan[] = [];
    markets.forEach((x, k) => {
      const prices = pre[2 * k] as readonly [readonly bigint[], bigint, number] | null;
      const params = pre[2 * k + 1] as { slippageAllowanceBps: number } | null;
      const debts = ctx.snapshot.spokeReserves.filter((r) => r.spoke.toLowerCase() === x.spoke.toLowerCase());
      x.tokens.forEach((token, i) => {
        for (const d of debts) {
          if (d.asset.toLowerCase() === token.toLowerCase()) continue; // a pool token that is the debt asset needs no route
          for (const kind of [0, 1]) plans.push({ marketId: x.marketId, token, tokenDecimals: x.tokenDecimals[i]!, tokenPrice: prices ? asBig(prices[0][i]) : 0n, debt: { asset: d.asset, decimals: d.decimals, price: BigInt(d.debtPrice) }, kind, slippageBps: params ? BigInt(params.slippageAllowanceBps) : -1n });
        }
      });
    });
    const meta = await some(ctx.views, plans.flatMap((p) => [
      { address: registry, abi: marketRegistryAbi, functionName: "getRoute", args: [BigInt(p.marketId), p.token, p.debt.asset, p.kind] },
      { address: store, abi: parameterStoreAbi, functionName: "routeDepthThreshold", args: [BigInt(p.marketId), p.token, p.debt.asset, p.kind] },
    ]));

    const out = new Map<string, SlotResult | null>();
    for (const [k, p] of plans.entries()) {
      const key = slotKey(p.marketId, p.token, p.debt.asset, p.kind);
      const route = meta[2 * k] as readonly [Address, boolean] | null;
      const threshold = meta[2 * k + 1] as bigint | null;
      if (!route || threshold === null || p.tokenPrice === 0n || p.debt.price === 0n || p.slippageBps < 0n) {
        out.set(key, null);
        continue;
      }
      if (route[0] === ZERO) continue; // no route in this slot (a backup not listed): nothing to measure
      const base = { marketId: p.marketId, token: p.token, debtAsset: p.debt.asset, kind: p.kind, route: route[0], threshold };
      // Pool-token input worth `num/den` of the threshold at the oracle prices.
      const input = (num: bigint, den: bigint) => (num * threshold * p.debt.price * 10n ** BigInt(p.tokenDecimals)) / (den * p.tokenPrice * 10n ** BigInt(p.debt.decimals));
      const minOut = (num: bigint, den: bigint) => (num * threshold * (10_000n - p.slippageBps)) / (den * 10_000n);
      const stressIn = input(1n, 1n);
      if (threshold === 0n) {
        out.set(key, { ...base, stressIn: 0n, minOut100: 0n, at120: "", at100: "", depth: "noThreshold", gsmRoom: null });
        continue;
      }
      if (!slotsOf.has(p.token.toLowerCase())) slotsOf.set(p.token.toLowerCase(), await findSlots(ctx.rpc, p.token, lps));
      const slots = slotsOf.get(p.token.toLowerCase())!;
      let at120 = "token storage slots not found";
      let at100 = at120;
      let depth: SlotResult["depth"] = "notSimulated";
      if (slots) {
        const setup = { lpVaultSwap: lps, lock, route: route[0], token: p.token, slots };
        const run = async (num: bigint, den: bigint) => {
          const r = await simulateSwap(ctx.rpc, setup, input(num, den));
          return { text: r.ok ? r.amountOut.toString(10) : `reverted: ${r.error}`, passes: r.ok && r.amountOut >= minOut(num, den) };
        };
        const a = await run(6n, 5n);
        const b = await run(1n, 1n);
        [at120, at100] = [a.text, b.text];
        depth = a.passes ? "120" : b.passes ? "100" : "below";
      }
      // GSM exposure room, for a peg-module route whose module answers the GSM's views.
      let gsmRoom: bigint | null = null;
      const [type, deps] = await some(ctx.views, [
        { address: route[0], abi: routeViews, functionName: "routeType" },
        { address: route[0], abi: routeViews, functionName: "dependencies" },
      ]);
      const module = Number(type) === 0 && Array.isArray(deps) && deps.length > 0 ? (deps[deps.length - 1] as Address) : null;
      if (module) {
        const [cap, held] = await some(ctx.views, [
          { address: module, abi: gsmViews, functionName: "getExposureCap" },
          { address: module, abi: gsmViews, functionName: "getAvailableUnderlyingLiquidity" },
        ]);
        if (cap !== null && held !== null) gsmRoom = asBig(cap) > asBig(held) ? asBig(cap) - asBig(held) : 0n;
      }
      out.set(key, { ...base, stressIn, minOut100: minOut(1n, 1n), at120, at100, depth, gsmRoom });
    }
    return { measuredAt: ctx.block.timestamp, block: ctx.block.number, slots: out };
  }

  return {
    name: "routes",
    async read(ctx) {
      // Measured when due, and again on the confirming read of the measurement's own block.
      const due = last === null || ctx.block.timestamp - last.measuredAt >= intervalSeconds || ctx.block.number === last.block;
      return due ? measure(ctx) : last!;
    },
    evaluate(input) {
      if (input !== last) last = input;
      const out: Finding[] = [];
      for (const [key, s] of input.slots) {
        const subject = `route:${key}`;
        if (!s) {
          out.push({ signal: "M-11", kind: "unread", level: "ok", subject, detail: {} });
          out.push({ signal: "M-12", kind: "unread", level: "ok", subject, detail: {} });
          continue;
        }
        const detail = { market: s.marketId, token: s.token, debtAsset: s.debtAsset, kind: s.kind === 0 ? "primary" : "backup", route: s.route, threshold: s.threshold.toString(10), measuredAtBlock: input.block.toString(10) };
        out.push({ signal: "M-11", kind: "condition", level: m11(s), subject, detail: { ...detail, depth: s.depth, outAt120: s.at120, outAt100: s.at100, minOutAt100: s.minOut100.toString(10) } });
        if (s.gsmRoom !== null) out.push({ signal: "M-12", kind: "condition", level: m12(s.gsmRoom, s.stressIn), subject, detail: { ...detail, gsmRoom: s.gsmRoom.toString(10), stressInput: s.stressIn.toString(10) } });
      }
      return out;
    },
    evidence: (input, subject) => {
      const s = input.slots.get(subject.slice("route:".length));
      return s ? text({ depth: s.depth, gsmRoom: s.gsmRoom, threshold: s.threshold }) : null;
    },
    save: () => ({ last, slotsOf: new Map(slotsOf) }),
    restore(s) {
      const saved = s as { last: RoutesInput | null; slotsOf: Map<string, TokenSlots | null> };
      last = saved.last;
      saved.slotsOf.forEach((v, k) => slotsOf.set(k, v));
    },
  };
}
