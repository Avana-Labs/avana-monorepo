// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Live reads: one wallet's accounts read at the chain head over Convex's RPC, for clients that cannot read the chain
// themselves (Ask AI, server-rendered pages). Each market's account is the wallet's proxy there
// (`AaveAdapter.accountOf`, one per wallet and market; `predictAccount` before the first pledge), read on the market's
// Spoke (`getUserAccountData`, and each debt reserve's `getUserTotalDebt`). Nothing is stored; each wallet may ask a
// bounded number of times a minute.

import { v } from "convex/values";
import { parseAbi, zeroAddress } from "viem";
import { aaveAdapterAbi } from "@avana/protocol/abis";
import { internal } from "../_generated/api";
import { action, internalQuery } from "../_generated/server";
import { type AccountSummary, type AccountViewLike, accountSummary } from "../lib/accounts.ts";
import { rpcClient } from "../lib/rpc.ts";

const PER_WALLET_PER_MINUTE = 30;
const ALL_PER_MINUTE = 1_200;
/** Markets one request reads at most; a wallet with more accounts is read in the order they were opened. */
const MAX_MARKETS = 32;

const spokeAbi = parseAbi([
  "function getUserAccountData(address user) view returns ((uint256 riskPremium, uint256 avgCollateralFactor, uint256 healthFactor, uint256 totalCollateralValue, uint256 totalDebtValueRay, uint256 activeCollateralCount, uint256 borrowCount))",
  "function getUserTotalDebt(uint256 reserveId, address user) view returns (uint256)",
  "function getReserve(uint256 reserveId) view returns ((address underlying, address hub, uint16 assetId, uint8 decimals, uint24 collateralRisk, uint8 flags, uint32 dynamicConfigKey))",
]);

type Hex = `0x${string}`;

export const marketsOf = internalQuery({
  args: { chainId: v.number(), wallet: v.string() },
  handler: async (ctx, { chainId, wallet }) => {
    const rows = await ctx.db.query("accounts").withIndex("by_wallet", (q) => q.eq("wallet", wallet)).collect();
    // A market is `integrationId:marketId`: each integration's RiskModule numbers its own markets.
    const ids = [...new Set(rows.filter((r) => r.chainId === chainId).map((r) => `${r.integrationId}:${r.marketId}`))];
    const d = await ctx.db.query("deployments").withIndex("by_chain", (q) => q.eq("chainId", chainId)).unique();
    return {
      served: d !== null && (d.integrations ?? []).length > 0,
      adapters: (d?.integrations ?? []).map((x) => ({ integrationId: x.integrationId, aaveAdapter: x.aaveAdapter })),
      markets: (d?.markets ?? []).map((m) => ({ marketId: m.marketId, integrationId: m.integrationId, spoke: m.spoke })),
      debtReserves: d?.debtReserves ?? [],
      marketIds: ids.slice(0, MAX_MARKETS),
    };
  },
});

export type LiveAccounts = { readonly status: "ok"; readonly accounts: readonly AccountSummary[] } | { readonly status: "rateLimited" };

/**
 * `marketIds` name markets as `integrationId:marketId`; a bare decimal ID (an older caller) reads that ID on every
 * integration that lists it. Each summary carries its `integrationId`.
 */
export const accounts = action({
  args: { chainId: v.number(), wallet: v.string(), marketIds: v.optional(v.array(v.string())) },
  handler: async (ctx, { chainId, wallet, marketIds }): Promise<LiveAccounts> => {
    if (!/^0x[0-9a-fA-F]{40}$/.test(wallet)) throw new Error("wallet is a 20-byte address");
    if (marketIds && (marketIds.length > MAX_MARKETS || marketIds.some((m) => !/^(\d{1,9}:)?\d{1,78}$/.test(m)))) {
      throw new Error(`marketIds are up to ${MAX_MARKETS} markets, each integrationId:marketId or a decimal id`);
    }
    const w = wallet.toLowerCase() as Hex;
    if (!(await ctx.runMutation(internal.wallet.history.hit, { key: "live:*", limit: ALL_PER_MINUTE }))) return { status: "rateLimited" };
    if (!(await ctx.runMutation(internal.wallet.history.hit, { key: `live:${w}`, limit: PER_WALLET_PER_MINUTE }))) return { status: "rateLimited" };
    const known = await ctx.runQuery(internal.wallet.live.marketsOf, { chainId, wallet: w });
    if (!known.served) throw new Error(`chain ${chainId} is not served`);
    const named = marketIds ?? known.marketIds;
    const markets = known.markets.filter((m) => named.some((id) => id === `${m.integrationId}:${m.marketId}` || id === m.marketId)).slice(0, MAX_MARKETS);
    if (markets.length === 0) return { status: "ok", accounts: [] };
    const client = rpcClient(chainId);
    const block = await client.getBlockNumber();
    const out: AccountSummary[] = [];
    for (const market of markets) {
      const id = market.marketId;
      const adapter = known.adapters.find((a) => a.integrationId === market.integrationId)?.aaveAdapter;
      if (!adapter) continue;
      const read = <T>(address: string, abi: readonly unknown[], functionName: string, args: readonly unknown[]) =>
        client.readContract({ address: address as Hex, abi: abi as never, functionName: functionName as never, args: args as never, blockNumber: block }) as Promise<T>;
      const deployedAccount = await read<Hex>(adapter, aaveAdapterAbi, "accountOf", [w, BigInt(id)]);
      const deployed = deployedAccount !== zeroAddress;
      const proxy = deployed ? deployedAccount : await read<Hex>(adapter, aaveAdapterAbi, "predictAccount", [w, BigInt(id)]);
      const data = deployed
        ? await read<{ riskPremium: bigint; avgCollateralFactor: bigint; healthFactor: bigint; totalCollateralValue: bigint; totalDebtValueRay: bigint }>(market.spoke, spokeAbi, "getUserAccountData", [proxy])
        : { riskPremium: 0n, avgCollateralFactor: 0n, healthFactor: (1n << 256n) - 1n, totalCollateralValue: 0n, totalDebtValueRay: 0n };
      const debts = [];
      if (deployed) {
        for (const r of known.debtReserves.filter((x) => x.spoke === market.spoke)) {
          const total = await read<bigint>(market.spoke, spokeAbi, "getUserTotalDebt", [BigInt(r.reserveId), proxy]);
          if (total === 0n) continue;
          const reserve = await read<{ underlying: string }>(market.spoke, spokeAbi, "getReserve", [BigInt(r.reserveId)]);
          debts.push({ reserveId: BigInt(r.reserveId), asset: reserve.underlying, total, paused: false, priceFresh: true });
        }
      }
      const view: AccountViewLike = { blockNumber: block, integrationId: market.integrationId, marketId: BigInt(id), proxy, deployed, ...data, walletFrozen: false, breakerReasons: 0, debts };
      out.push(accountSummary(view));
    }
    return { status: "ok", accounts: out };
  },
});
