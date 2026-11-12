// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Current values: every 30 s per chain the sampler reads the snapshot (Hub assets, Spoke slices, CDP debt reserves,
// markets) at one block over Convex's RPC and writes the rows the pages read, with the gas price for the fee quote.
// A market, pool or asset listed on chain appears at the next run; its content arrives with the listing metadata.

import { v } from "convex/values";
import { parseAbi } from "viem";
import { readChainSnapshot } from "@avana/services-common/views";
import { internal } from "../_generated/api";
import { internalAction, internalMutation } from "../_generated/server";
import { pinnedViews, rpcClient } from "../lib/rpc.ts";

const feedAbi = parseAbi(["function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)", "function decimals() view returns (uint8)"]);

export const refresh = internalAction({
  args: { chainId: v.number() },
  handler: async (ctx, { chainId }) => {
    const { deployment } = await ctx.runQuery(internal.ingest.apply.state, { chainId });
    if (!deployment) return;
    const client = rpcClient(chainId);
    const block = await client.getBlock({ blockTag: "latest" });
    const snapshot = await readChainSnapshot(
      pinnedViews(client, block.number),
      { chainId, lens: deployment.lens as `0x${string}`, lendSpoke: deployment.lendSpoke as `0x${string}`, cdpSpokes: deployment.cdpSpokes as `0x${string}`[], coverageSpokes: deployment.coverageSpokes as { address: `0x${string}`; asset: `0x${string}` }[] },
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
