// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Pending settlement: when Collateralization holds pending seized units for a market (SeizureReconciled,
// getPending), call LPVaultSwap.settlePending(marketId, settlementReserve(marketId)) once the market's price passes
// the liquidation gates. It pays the caller nothing; the proceeds fund the market's First-Loss Reserve. It is sent from
// the signer directly: no funding is needed, so no helper is involved.

import { encodeFunctionData } from "viem";
import { lpVaultSwapAbi } from "@avana/protocol/abis";
import type { ManifestMarket } from "@avana/services-common";
import type { BlockContext, Job } from "../types.ts";

interface Decision {
  readonly market: ManifestMarket;
  readonly debtReserveId: bigint;
  readonly units: bigint;
}

export function settlePendingJob(): Job<ManifestMarket, Decision> {
  return {
    kind: "settlePending",

    // Every market of the manifest: getPending is one read per market and catches units a missed event left out.
    async discover(ctx: BlockContext) {
      return ctx.config.manifest.markets;
    },

    async check(ctx, market) {
      const view = await ctx.reader.pendingSettlement(market.vaultToken.address);
      if (view.units === 0n) return { act: false, reason: "nothingPending" };
      if (!view.settleable) return { act: false, reason: "marketNotLiquidatable", detail: "pending units not settleable at this price" };
      const debtReserveId = await ctx.reader.settlementReserve(market.marketId);
      return { act: true, decision: { market, debtReserveId, units: view.settleableUnits } };
    },

    async build(ctx, { market, debtReserveId, units }) {
      const m = ctx.config.manifest;
      return {
        job: "settlePending",
        subject: `${ctx.config.chain.id}:market:${market.marketId}`,
        to: m.avana.lpVaultSwap.address,
        data: encodeFunctionData({ abi: lpVaultSwapAbi, functionName: "settlePending", args: [market.marketId, debtReserveId] }),
        deadline: null,
        reservations: [],
        targets: [
          { kind: "upgradeable", address: m.avana.lpVaultSwap.address, implementation: m.avana.lpVaultSwap.implementation },
          { kind: "upgradeable", address: market.lpOracle.address, implementation: market.lpOracle.implementation },
          { kind: "immutable", address: m.avana.collateralization.address, codeHash: m.avana.collateralization.codeHash },
          { kind: "immutable", address: market.vaultToken.address, codeHash: market.vaultToken.codeHash },
          ...market.routes.map((r) => ({ kind: "immutable" as const, address: r.address, codeHash: r.codeHash })),
        ],
        params: { marketId: market.marketId, debtReserveId, units },
      };
    },
  };
}
