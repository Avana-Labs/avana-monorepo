// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Current values: every 30 s per chain the sampler reads the snapshot (Hubs, Hub assets, Spoke slices, Hub-to-Hub
// credit lines, CDP debt reserves, markets) at one block over Convex's RPC and writes the rows the pages read, with
// the gas price for the fee quote. A Hub, Spoke, market, pool or asset listed on chain appears at the next run; its
// content arrives with the listing metadata.

import { v } from "convex/values";
import { parseAbi } from "viem";
import { type ChainDeployment, readChainSnapshot } from "@avana/services-common/views";
import type { Doc } from "../_generated/dataModel";
import { internal } from "../_generated/api";
import { internalAction, internalMutation } from "../_generated/server";
import { pinnedViews, rpcClient } from "../lib/rpc.ts";

const feedAbi = parseAbi(["function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)", "function decimals() view returns (uint8)"]);

type Hex = `0x${string}`;

/** The sampler's starting addresses; Hubs and CDP Spokes listed later are found by the reader on chain. */
export function chainDeployment(d: Doc<"deployments">): ChainDeployment {
  return {
    chainId: d.chainId,
    lens: d.lens as Hex,
    marketRegistry: d.marketRegistry as Hex,
    hubs: d.hubs.map((h) => ({ address: h.address as Hex, label: h.label })),
    lendSpokes: d.lendSpokes as Hex[],
    cdpSpokes: d.cdpSpokes as Hex[],
    coverageSpokes: d.coverageSpokes.map((c) => ({ address: c.address as Hex, asset: c.asset as Hex, ...(c.hub ? { hub: c.hub as Hex } : {}) })),
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

    const [, answer] = await client.readContract({ address: deployment.nativeUsdFeed as `0x${string}`, abi: feedAbi, functionName: "latestRoundData", blockNumber: block.number });
    const decimals = await client.readContract({ address: deployment.nativeUsdFeed as `0x${string}`, abi: feedAbi, functionName: "decimals", blockNumber: block.number });
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
