// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Breaker and configuration pokes. Every block the keeper simulates RiskModule.pokeBreakers(marketId) for every
// active market and RiskModule.pokeConfig(spoke) for every CDP Spoke of the manifest that the MarketRegistry approved
// (pokeConfig reverts UnknownSpoke for any other), and sends only when the simulation returns
// a non-zero result: pokeBreakers records a breach only when a condition is true, and pokeConfig writes nothing
// when it finds no drift, so a send in any other block would change no state (EMG-053, REQ-RISK-090/091).

import { type Address, decodeFunctionResult, encodeFunctionData } from "viem";
import { riskModuleAbi } from "@avana/protocol/abis";
import type { BlockContext, Job, JobKind } from "../types.ts";

type Target = { readonly kind: "market"; readonly marketId: bigint } | { readonly kind: "spoke"; readonly spoke: Address };

function calldata(t: Target) {
  return t.kind === "market"
    ? encodeFunctionData({ abi: riskModuleAbi, functionName: "pokeBreakers", args: [t.marketId] })
    : encodeFunctionData({ abi: riskModuleAbi, functionName: "pokeConfig", args: [t.spoke] });
}

export function breakerPokeJob(): Job<Target, Target> {
  return {
    kind: "breakerPoke",

    async discover(ctx: BlockContext) {
      const m = ctx.config.manifest;
      const approved = new Set((await ctx.reader.approvedSpokes()).map((a) => a.toLowerCase()));
      return [
        ...m.markets.map((x): Target => ({ kind: "market", marketId: x.marketId })),
        ...m.aave.borrowSpokes.filter((s) => approved.has(s.address.toLowerCase())).map((s): Target => ({ kind: "spoke", spoke: s.address })),
      ];
    },

    async check(ctx, t) {
      const riskModule = ctx.config.manifest.avana.riskModule.address;
      const { data } = await ctx.reader.callAt(riskModule, calldata(t));
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
