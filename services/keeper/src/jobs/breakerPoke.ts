// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Breaker and configuration pokes. The keeper simulates RiskModule.pokeBreakers(marketId) for every active market and
// RiskModule.pokeConfig(spoke) for every CDP Spoke of the manifest that the MarketRegistry approved (pokeConfig
// reverts UnknownSpoke for any other), and sends only when the simulation returns a non-zero result: pokeBreakers
// records a breach only when a condition is true, and pokeConfig writes nothing when it finds no drift, so a send in
// any other block would change no state (EMG-053, REQ-RISK-090/091).
// Breaker pokes are safety actions: they are checked at every head, all markets in one simulation (chain/reads.ts,
// `breakerPokes`). Configuration pokes may run at the slow cadence (runtime/chainLoop.ts).

import { type Address, type Hex, decodeFunctionResult, encodeFunctionData } from "viem";
import { riskModuleAbi } from "@avana/protocol/abis";
import type { BlockContext, Job, JobKind } from "../types.ts";

type Target = { readonly kind: "market"; readonly marketId: bigint } | { readonly kind: "spoke"; readonly spoke: Address };

function calldata(t: Target) {
  return t.kind === "market"
    ? encodeFunctionData({ abi: riskModuleAbi, functionName: "pokeBreakers", args: [t.marketId] })
    : encodeFunctionData({ abi: riskModuleAbi, functionName: "pokeConfig", args: [t.spoke] });
}

const marketsOf = (ctx: BlockContext) => ctx.config.manifest.markets.map((x) => x.marketId);

/** The simulated return of the target's poke at this block; a reverting one throws its revert, as a lone eth_call. */
async function simulated(ctx: BlockContext, t: Target): Promise<Hex | undefined> {
  const riskModule = ctx.config.manifest.avana.riskModule.address;
  if (t.kind === "market") {
    const batched = (await ctx.reader.breakerPokes(riskModule, marketsOf(ctx))).get(t.marketId);
    if (batched !== null) return batched;
  }
  return (await ctx.reader.callAt(riskModule, calldata(t))).data;
}

function pokeJob(kind: "breakerPoke" | "configPoke", discover: (ctx: BlockContext) => Promise<Target[]>, prefetch?: Job<Target, Target>["prefetch"]): Job<Target, Target> {
  return {
    kind,
    discover,
    ...(prefetch ? { prefetch } : {}),

    async check(ctx, t) {
      const data = await simulated(ctx, t);
      if (!data) return { act: false, reason: "conditionFalse" };
      const fn = t.kind === "market" ? "pokeBreakers" : "pokeConfig";
      const result = decodeFunctionResult({ abi: riskModuleAbi, functionName: fn, data }) as number | bigint;
      return BigInt(result) === 0n ? { act: false, reason: "conditionFalse" } : { act: true, decision: t };
    },

    async build(ctx, t) {
      const rm = ctx.config.manifest.avana.riskModule;
      const job: JobKind = t.kind === "market" ? "breakerPoke" : "configPoke";
      return {
        job,
        // Sent only on a non-zero simulated result: a breach or a drift to record now.
        jobClass: "urgent",
        subject: t.kind === "market" ? `${ctx.config.chain.id}:market:${t.marketId}` : `${ctx.config.chain.id}:${t.spoke}`,
        to: rm.address,
        data: calldata(t),
        deadline: null,
        reservations: [],
        targets: [
          { kind: "upgradeable", address: rm.address, implementation: rm.implementation },
          { kind: "upgradeable", address: ctx.config.manifest.avana.marketRegistry.address, implementation: ctx.config.manifest.avana.marketRegistry.implementation },
        ],
        params: t.kind === "market" ? { marketId: t.marketId } : { spoke: t.spoke },
      };
    },
  };
}

/** pokeBreakers for every active market; the simulations of all markets travel as one eth_call. */
export function breakerPokeJob(): Job<Target, Target> {
  return pokeJob(
    "breakerPoke",
    async (ctx) => marketsOf(ctx).map((marketId): Target => ({ kind: "market", marketId })),
    async (ctx) => void (await ctx.reader.breakerPokes(ctx.config.manifest.avana.riskModule.address, marketsOf(ctx))),
  );
}

/** pokeConfig for every CDP Spoke of the manifest that the MarketRegistry approved. */
export function configPokeJob(): Job<Target, Target> {
  return pokeJob("configPoke", async (ctx) => {
    const approved = new Set((await ctx.reader.approvedSpokes()).map((a) => a.toLowerCase()));
    return ctx.config.manifest.aave.borrowSpokes.filter((s) => approved.has(s.address.toLowerCase())).map((s): Target => ({ kind: "spoke", spoke: s.address }));
  });
}
