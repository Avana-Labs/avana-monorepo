// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Typed stub. A wallet's balances are read live by the app over RPC at a stated block (Lend Spoke
// `getUserSuppliedAssets`, `Lens.getAccount`, ERC-20 balances), never served from Convex (README, "Live values").
// The query keeps the dashboard's shape and returns empty buckets.

import { v } from "convex/values";
import { query } from "../_generated/server";

export interface ProductBalances {
  readonly lend: readonly { marketId: string; assetId: string; symbol: string; amount: number; valueUsd: number; state: "available" | "deposited"; updatedAt: number }[];
  readonly borrow: readonly { marketId?: string; assetId?: string; poolId?: string; symbol: string; amount: number; valueUsd: number; unitPriceUsd?: number; ltvPct?: number; state: "poolAvailable" | "collateral" | "debt" | "claimableFees" }[];
  readonly multiply: readonly never[];
  readonly liquid: readonly { assetId: string; symbol: string; amount: number; valueUsd: number; state: "available" }[];
}

export const listForWallet = query({
  args: { wallet: v.string() },
  handler: async (): Promise<ProductBalances> => ({ lend: [], borrow: [], multiply: [], liquid: [] }),
});
