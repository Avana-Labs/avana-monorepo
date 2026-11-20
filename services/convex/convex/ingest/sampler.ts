// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Current values: every 60 s per chain the sampler reads the snapshot (Hubs, Hub assets with their draw-cap coverage,
// Spoke slices, CDP debt reserves, markets: two per pool) at one block over Convex's RPC and writes the rows the pages
// read, with the gas price for the fee quote. A market listed on chain appears once its release manifest is written
// (`deployments:setFromManifest`); its content arrives with the listing metadata.

import { v } from "convex/values";
import { parseAbi } from "viem";
import { type ChainDeployment, readChainSnapshot } from "@avana/services-common/views";
import type { Doc } from "../_generated/dataModel";
import { internal } from "../_generated/api";
import { internalAction, internalMutation } from "../_generated/server";
import { MULTICALL3_ADDRESS } from "@avana/services-common/chains";
import { pinnedViews, rpcClient } from "../lib/rpc.ts";

const feedAbi = parseAbi(["function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)", "function decimals() view returns (uint8)"]);

type Hex = `0x${string}`;

/** The addresses the sampler reads, from the deployment row the manifest wrote. */
export function chainDeployment(d: Doc<"deployments">): ChainDeployment {
  const ZERO = "0x0000000000000000000000000000000000000000" as Hex;
  const riskModuleOf = new Map((d.integrations ?? []).map((x) => [x.integrationId, x.riskModule as Hex]));
  return {
    chainId: d.chainId,
    hubs: d.hubs.map((h) => ({ address: h.address as Hex, label: h.label, tier: h.tier })),
    lendSpokes: d.lendSpokes as Hex[],
    cdpSpokes: d.cdpSpokes.map((s) => ({ address: s.address as Hex, hub: (s.hub ?? ZERO) as Hex })),
    firstLossReserves: d.firstLossReserves.map((c) => ({ address: c.address as Hex, asset: c.asset as Hex, hub: (c.hub ?? ZERO) as Hex })),
    deficitOffsets: (d.deficitOffsets ?? []).map((c) => ({ address: c.address as Hex, asset: c.asset as Hex, hub: c.hub as Hex })),
    riskModules: (d.integrations ?? []).map((x) => x.riskModule as Hex),
    markets: (d.markets ?? []).flatMap((m) => {
      const riskModule = riskModuleOf.get(m.integrationId);
      return riskModule
        ? [{ ...m, marketId: BigInt(m.marketId), reserveId: BigInt(m.reserveId), riskModule, pool: m.pool as Hex, spoke: m.spoke as Hex, hub: m.hub as Hex, vaultToken: m.vaultToken as Hex, lpOracle: m.lpOracle as Hex, tokens: m.tokens as Hex[] }]
        : [];
    }),
    debtReserves: (d.debtReserves ?? []).map((r) => ({ spoke: r.spoke as Hex, reserveId: BigInt(r.reserveId), fixedPrice: r.fixedPrice })),
  };
}

export const refresh = internalAction({
  args: { chainId: v.number() },
  handler: async (ctx, { chainId }) => {
    const { deployment } = await ctx.runQuery(internal.ingest.apply.state, { chainId });
    if (!deployment) return;
    const client = rpcClient(chainId);
    const block = await client.getBlock({ blockTag: "latest" });
    const snapshot = await readChainSnapshot(
      pinnedViews(client, block.number),
      chainDeployment(deployment),
      { blockNumber: block.number, timestamp: Number(block.timestamp) },
    );
    await ctx.runMutation(internal.ingest.apply.applySnapshot, { snapshot });

    // The feed's answer and decimals in one eth_call.
    const feed = deployment.nativeUsdFeed as `0x${string}`;
    const [[, answer], decimals] = await client.multicall({
      contracts: [
        { address: feed, abi: feedAbi, functionName: "latestRoundData" },
        { address: feed, abi: feedAbi, functionName: "decimals" },
      ],
      allowFailure: false,
      blockNumber: block.number,
      multicallAddress: MULTICALL3_ADDRESS,
    });
    const nativeUsd8 = decimals >= 8 ? answer / 10n ** BigInt(decimals - 8) : answer * 10n ** BigInt(8 - decimals);
    const priorityFeeWei = await client.estimateMaxPriorityFeePerGas();
    await ctx.runMutation(internal.ingest.sampler.storeGas, {
      chainId,
      baseFeeWei: (block.baseFeePerGas ?? 0n).toString(),
      priorityFeeWei: priorityFeeWei.toString(),
      nativeUsd8: nativeUsd8.toString(),
      blockNumber: block.number.toString(),
    });
  },
});

export const storeGas = internalMutation({
  args: { chainId: v.number(), baseFeeWei: v.string(), priorityFeeWei: v.string(), nativeUsd8: v.string(), blockNumber: v.string() },
  handler: async (ctx, a) => {
    const row = { ...a, updatedAt: Date.now() };
    const existing = await ctx.db.query("chainGas").withIndex("by_chain", (q) => q.eq("chainId", a.chainId)).unique();
    if (existing) await ctx.db.replace(existing._id, row);
    else await ctx.db.insert("chainGas", row);
  },
});
