// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Each page's feed: the Lend page shows the Lend Spoke's supplies and the CDP Spokes' draws on its asset, a Borrow
// asset page its Spoke's reserve events, a pool page Avana's account events, and no event appears twice on a page.
// Configuration events become changelog rows with the previous value.

import { describe, expect, it } from "vitest";
import type { ExportRecord } from "@avana/services-common/export";
import { type Resolver, decodeRecord, feedRow } from "../convex/lib/activity.ts";

const LEND = "0x2222222222222222222222222222222222222222";
const CDP = "0x5555555555555555555555555555555555555555";
const HUB = "0x1111111111111111111111111111111111111111";
const WALLET = "0xaaaa00000000000000000000000000000000beef";
const PROXY = "0xbbbb00000000000000000000000000000000cafe";

const res: Resolver = {
  chainId: 1,
  isLendSpoke: (s) => s === LEND,
  hubAssetOfReserve: async (spoke, id) => (spoke === LEND && id === "0") || (spoke === CDP && id === "1") ? `1:${HUB}:1` : null,
  hubAssetOfUnderlying: async () => `1:${HUB}:1`,
  spokeReserveOfAsset: async (spoke) => `1:${spoke}:1`,
  spokeReserveOfHubAsset: async (spoke) => `1:${spoke}:1`,
  marketOfCollateralReserve: async (spoke, id) => (spoke === CDP && id === "11" ? "1:4" : null),
  account: async (proxy) => (proxy === PROXY ? { wallet: WALLET, marketKey: "1:4" } : null),
  previous: async (_s, _k, parameter) => (parameter === "Collateral risk" ? "3%" : null),
};

let n = 0;
const rec = (kind: string, address: string, args: Record<string, unknown>): ExportRecord => {
  n += 1;
  const tx = `0x${n.toString(16).padStart(64, "0")}` as const;
  return { key: `1:${tx}:0`, kind, blockNumber: "100", blockHash: tx, txHash: tx, logIndex: 0, address: address as `0x${string}`, args };
};

const price = () => ({ symbol: "USDC", decimals: 6, priceUsd8: 100_000_000n });

describe("feeds by page", () => {
  it("files a CDP borrow under its Hub asset and its Spoke reserve, not under the market", async () => {
    const d = await decodeRecord(rec("AaveSpoke.Borrow", CDP, { reserveId: "1", caller: WALLET, user: PROXY, drawnShares: "1", drawnAmount: "2500000000" }), 1_000, res);
    expect(d.log).toMatchObject({ hubAssetKey: `1:${HUB}:1`, spokeReserveKey: `1:${CDP}:1`, wallet: WALLET });
    expect(d.log.marketKey).toBeUndefined();
    expect(feedRow(d.log, "lend", price)).toMatchObject({ kind: "borrow", amountUsd: 2_500, amountLabel: "$2.50K", tokenSymbol: "USDC" });
    expect(feedRow(d.log, "asset", price)?.kind).toBe("borrow");
    expect(feedRow(d.log, "pool", price)).toBeNull();
  });

  it("files Avana's Borrowed under the market only, for the pool page", async () => {
    const d = await decodeRecord(rec("AaveAdapter.Borrowed", "0xcccc000000000000000000000000000000000001", { wallet: WALLET, marketId: "4", debtReserveId: "1", amount: "2500000000" }), 1_000, res);
    expect(d.log).toMatchObject({ marketKey: "1:4", wallet: WALLET });
    expect(d.log.hubAssetKey).toBeUndefined();
    expect(feedRow(d.log, "pool", price)?.kind).toBe("borrow");
  });

  it("shows Lend Spoke supplies on the Lend page and ignores supplies on other Spokes", async () => {
    const lend = await decodeRecord(rec("AaveSpoke.Supply", LEND, { reserveId: "0", user: WALLET, suppliedShares: "1", suppliedAmount: "1000000" }), 1_000, res);
    expect(feedRow(lend.log, "lend", price)).toMatchObject({ kind: "supply", walletLabel: "0xaaaa…beef" });
    const collateral = await decodeRecord(rec("AaveSpoke.Supply", CDP, { reserveId: "11", user: PROXY, suppliedShares: "1", suppliedAmount: "1" }), 1_000, res);
    expect(collateral.log.hubAssetKey).toBeUndefined();
  });

  it("binds a wallet to its proxy from UserProxyCreated", async () => {
    const d = await decodeRecord(rec("AaveAdapter.UserProxyCreated", "0xcccc000000000000000000000000000000000001", { wallet: WALLET, spoke: CDP, marketId: "4", proxy: PROXY }), 1_000, res);
    expect(d.account).toEqual({ spoke: CDP, proxy: PROXY, wallet: WALLET, marketId: "4" });
  });
});

describe("changelog and listing events", () => {
  it("records a market's collateral risk change with its previous value", async () => {
    const d = await decodeRecord(rec("AaveSpoke.UpdateReserveConfig", CDP, { reserveId: "11", config: { collateralRisk: 500, paused: false, frozen: false, borrowable: false } }), 1_000, res);
    expect(d.changes).toEqual([{ scope: "pool", key: "1:4", parameter: "Collateral risk", previous: "3%", current: "5%" }]);
  });

  it("names the Lend Spoke's cap change a supply cap and a CDP Spoke's a draw cap", async () => {
    const lend = await decodeRecord(rec("AaveHub.UpdateSpokeConfig", HUB, { assetId: "1", spoke: LEND, config: { addCap: "12000000", drawCap: "0" } }), 1_000, res);
    expect(lend.changes[0]).toMatchObject({ scope: "lend", parameter: "Supply cap", current: "12000000" });
    const cdp = await decodeRecord(rec("AaveHub.UpdateSpokeConfig", HUB, { assetId: "1", spoke: CDP, config: { addCap: "0", drawCap: "4000000" } }), 1_000, res);
    expect(cdp.changes[0]).toMatchObject({ scope: "asset", key: `1:${CDP}:1`, parameter: "Draw cap", current: "4000000" });
  });

  it("turns a timelock salt and execution into a listing operation", async () => {
    const salt = `0x${"ab".repeat(32)}`;
    const scheduled = await decodeRecord(rec("AvanaTimelock.CallSalt", "0xdddd000000000000000000000000000000000001", { id: `0x${"01".repeat(32)}`, salt }), 1_000, res);
    expect(scheduled.listing).toEqual({ operationId: `0x${"01".repeat(32)}`, salt, executed: false });
    const executed = await decodeRecord(rec("AvanaTimelock.CallExecuted", "0xdddd000000000000000000000000000000000001", { id: `0x${"01".repeat(32)}`, index: "0" }), 1_000, res);
    expect(executed.listing?.executed).toBe(true);
  });
});
