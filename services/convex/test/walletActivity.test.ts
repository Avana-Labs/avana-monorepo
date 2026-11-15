// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The dashboard's activity rows: each event of the wallet maps to the page that shows it, priced in the token it
// moved, with an explorer link only when the chain has an explorer; events no page shows are left out.

import { describe, expect, it } from "vitest";
import { fixtureHubAsset, fixtureMarkets, fixtureSpokeReserves } from "@avana/services-common/fixtures";
import { hubAssetKey } from "../convex/lib/pages.ts";
import { explorerLinks } from "../convex/lib/explorer.ts";
import type { World } from "../convex/model.ts";
import { walletActivityRow } from "../convex/wallet/activity.ts";

const asset = { ...fixtureHubAsset, slug: "ethereum-usdc", updatedAt: 0 };
const market = { ...fixtureMarkets[0]!, slug: "ethereum-usdc-usdt", updatedAt: 0 };
const reserves = fixtureSpokeReserves.map((r) => ({ ...r, slug: `asset-${r.spoke.slice(2, 6)}`, updatedAt: 0 }));
const world = { markets: [market], reserves, hubAssets: [asset], assetsByKey: new Map([[hubAssetKey(asset), asset]]), content: [] } as unknown as World;
const TX = `0x${"12".repeat(32)}`;
const log = (kind: string, args: Record<string, unknown>, keys: Record<string, string>) => ({
  key: `1:${TX}:0`, chainId: 1, kind, blockNumber: "100", blockHash: `0x${"00".repeat(32)}`, txHash: TX, logIndex: 0, address: market.spoke, at: 1_767_225_600_000, args, wallet: "0x00000000000000000000000000000000000000a1", ...keys,
});

describe("wallet activity rows", () => {
  it("puts a market borrow on the pool page with its USD value and explorer link", () => {
    const r = walletActivityRow(world, log("AaveAdapter.Borrowed", { amount: "2500000000", debtReserveId: market.borrow[0]!.reserveId }, { marketKey: `1:${market.marketId}` }), () => "https://etherscan.io");
    expect(r).toMatchObject({ chainId: 1, kind: "borrow", page: { scope: "pool", slug: market.slug }, txHash: TX, href: `https://etherscan.io/tx/${TX}` });
  });

  it("puts a Lend supply on the Lend page and leaves the link out without an explorer", () => {
    const r = walletActivityRow(world, log("AaveSpoke.Supply", { suppliedAmount: "1000000" }, { hubAssetKey: hubAssetKey(asset) }), () => undefined);
    expect(r).toMatchObject({ kind: "supply", page: { scope: "lend", slug: "ethereum-usdc" } });
    expect(r?.href).toBeUndefined();
  });

  it("leaves out events no page shows", () => {
    expect(walletActivityRow(world, log("AaveAdapter.UserProxyCreated", {}, { marketKey: `1:${market.marketId}` }), () => undefined)).toBeNull();
  });
});

describe("explorer links", () => {
  it("builds links only for a https base and well-formed values", () => {
    const l = explorerLinks("https://basescan.org/")!;
    expect(l.tx(TX)).toBe(`https://basescan.org/tx/${TX}`);
    expect(l.address("0x00000000000000000000000000000000000000A1")).toBe("https://basescan.org/address/0x00000000000000000000000000000000000000a1");
    expect(l.block(123n)).toBe("https://basescan.org/block/123");
    expect(l.tx("0x12")).toBeUndefined();
    expect(explorerLinks("http://insecure.example")).toBeNull();
    expect(explorerLinks("")).toBeNull();
  });
});
