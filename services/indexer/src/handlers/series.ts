// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The hourly sampler: at one block an hour it reads the chain snapshot (every Hub asset of every Hub, Spoke slice, CDP
// debt reserve and market, both markets of each pool), the debt each market backs and each
// account's collateral and debt, and writes them as series points. Every point of one sample
// carries the same block, so the Spoke slices of a bucket add up to the Hub totals of the same bucket. Reads go through Ponder's client pinned to the sample block, so a reindex reads the
// same values from the archive node and a replay changes nothing.

import { type DecimalString, MULTICALL3_ADDRESS, scopeKey } from "@avana/services-common";
import { type CallResult, type ContractCall, type ViewClient, clPoolAbi, readChainSnapshot, spokeViewsAbi } from "@avana/services-common/views";
import { ponder, type Context } from "ponder:registry";
import schema from "ponder:schema";
import { eq } from "ponder";
import { deploymentOf } from "../config/sources.ts";
import { writeObservation } from "../lib/seriesWrite.ts";
import { stateFloor } from "../lib/stateFloor.ts";

const s = (x: bigint | number): DecimalString => x.toString(10);

function viewClient(context: Context): ViewClient {
  return {
    multicall: async (calls: readonly ContractCall[]) =>
      (await context.client.multicall({ contracts: calls as never, allowFailure: true, multicallAddress: MULTICALL3_ADDRESS })) as unknown as readonly CallResult[],
  };
}

ponder.on("SeriesSampler:block", async ({ event, context }) => {
  const chainId = context.chain.id;
  const timestamp = Number(event.block.timestamp);
  const blockNumber = event.block.number;
  // A restored development node has no state before its floor (lib/stateFloor.ts): the series start there.
  if (blockNumber < stateFloor(chainId)) return;
  const client = viewClient(context);
  const snap = await readChainSnapshot(client, deploymentOf(chainId), { blockNumber, timestamp });
  const at = { chainId, timestamp, blockNumber };

  for (const a of snap.hubAssets) {
    await writeObservation(context, {
      ...at,
      kind: "hubAsset",
      key: scopeKey(chainId, a.hub, a.assetId),
      values: {
        priceUsd8: a.priceUsd8,
        added: a.added,
        addedShares: a.addedShares,
        drawn: a.drawn,
        premium: a.premium,
        owed: a.owed,
        liquidity: a.liquidity,
        deficit: a.deficit,
        accruedFees: a.accruedFees,
        drawnIndexRay: a.drawnIndexRay,
        drawnRateRay: a.drawnRateRay,
        supplyRateRay: a.supplyRateRay,
        utilizationBps: s(a.utilizationBps),
      },
    });
  }
  for (const sl of snap.slices) {
    await writeObservation(context, {
      ...at,
      kind: "hubAssetSpoke",
      key: scopeKey(chainId, sl.hub, sl.assetId, sl.spoke),
      values: { added: sl.added, addedShares: sl.addedShares, owed: sl.owed, drawnShares: sl.drawnShares, premiumShares: sl.premiumShares, deficit: sl.deficit, addCap: sl.addCap, drawCap: sl.drawCap },
    });
  }

  // Accounts the AaveAdapters announced, with their collateral and debts. A market is its integration and its ID:
  // each RiskModule numbers its own markets.
  type Mk = { readonly integrationId: number; readonly marketId: string };
  const mkKey = (m: Mk) => `${m.integrationId}:${m.marketId}`;
  const ofAccount = (acc: { integrationId: number; marketId: bigint; spoke: string }) =>
    snap.markets.find((m) => m.integrationId === acc.integrationId && m.marketId === s(acc.marketId) && m.spoke === acc.spoke.toLowerCase());
  const accounts = (await context.db.sql.select().from(schema.account).where(eq(schema.account.chainId, chainId))).filter((acc) => ofAccount(acc) !== undefined);
  const reservesBySpoke = new Map<string, string[]>();
  for (const r of snap.spokeReserves) reservesBySpoke.set(r.spoke, [...(reservesBySpoke.get(r.spoke) ?? []), r.reserveId]);
  const calls: ContractCall[] = [];
  const plan = accounts.map((acc) => {
    const spoke = acc.spoke.toLowerCase() as `0x${string}`;
    const market = ofAccount(acc)!;
    const debtIds = reservesBySpoke.get(spoke) ?? [];
    const first = calls.length;
    calls.push({ address: spoke, abi: spokeViewsAbi, functionName: "getUserSuppliedAssets", args: [BigInt(market.reserveId), acc.proxy] });
    for (const id of debtIds) calls.push({ address: spoke, abi: spokeViewsAbi, functionName: "getUserDebt", args: [BigInt(id), acc.proxy] });
    return { acc, spoke, market, debtIds, first };
  });
  const results = calls.length > 0 ? await client.multicall(calls) : [];
  const ok = (i: number): unknown => {
    const r = results[i];
    if (!r || r.status !== "success") throw new Error(`account read ${calls[i]?.functionName} failed at block ${blockNumber}`);
    return r.result;
  };

  const priceOf = (spoke: string, reserveId: string) => {
    const r = snap.spokeReserves.find((x) => x.spoke === spoke && x.reserveId === reserveId)!;
    return snap.hubAssets.find((h) => h.hub === r.hub && h.assetId === r.assetId);
  };
  const marketDebt = new Map<string, { debt: bigint; borrowers: number; spoke: string; reserveId: string; market: string }>();
  const marketBorrowers = new Map<string, number>();
  for (const p of plan) {
    const collateral = ok(p.first) as bigint;
    let debtUsd8 = 0n;
    p.debtIds.forEach((id, j) => {
      const [drawn, premium] = ok(p.first + 1 + j) as [bigint, bigint];
      const debt = drawn + premium;
      if (debt === 0n) return;
      const key = `${mkKey(p.market)}:${id}`;
      const row = marketDebt.get(key) ?? { debt: 0n, borrowers: 0, spoke: p.spoke, reserveId: id, market: mkKey(p.market) };
      row.debt += debt;
      row.borrowers += 1;
      marketDebt.set(key, row);
      const asset = priceOf(p.spoke, id);
      if (asset) debtUsd8 += (debt * BigInt(asset.priceUsd8)) / 10n ** BigInt(asset.decimals);
    });
    if (debtUsd8 > 0n) marketBorrowers.set(mkKey(p.market), (marketBorrowers.get(mkKey(p.market)) ?? 0) + 1);
    const collateralUsd8 = (collateral * BigInt(p.market.acceptedPrice)) / 10n ** BigInt(p.market.vaultDecimals);
    await writeObservation(context, {
      ...at,
      kind: "position",
      key: scopeKey(chainId, p.spoke, p.acc.proxy),
      resolutions: ["day"],
      values: { integrationId: s(p.market.integrationId), marketId: p.market.marketId, collateralUnits: s(collateral), collateralUsd8: s(collateralUsd8), debtUsd8: s(debtUsd8) },
    });
  }

  for (const m of snap.markets) {
    let debtUsd8 = 0n;
    const borrowers = marketBorrowers.get(mkKey(m)) ?? 0;
    for (const d of marketDebt.values()) {
      if (d.market !== mkKey(m)) continue;
      const asset = priceOf(d.spoke, d.reserveId);
      if (asset) debtUsd8 += (d.debt * BigInt(asset.priceUsd8)) / 10n ** BigInt(asset.decimals);
      await writeObservation(context, { ...at, kind: "marketReserve", key: scopeKey(chainId, m.integrationId, m.marketId, d.spoke, d.reserveId), values: { debt: s(d.debt), borrowers: s(d.borrowers) } });
    }
    await writeObservation(context, {
      ...at,
      kind: "market",
      key: scopeKey(chainId, m.integrationId, m.marketId),
      values: { suppliedUnits: m.suppliedUnits, acceptedPrice: m.acceptedPrice, suppliedUsd8: m.suppliedUsd8, debtUsd8: s(debtUsd8), borrowers: s(borrowers) },
    });
  }
  // A dynamic-fee pool (Slipstream) reports its current fee; it is read here and applies to the next hour's swaps.
  for (const pool of await context.db.sql.select().from(schema.ammPool).where(eq(schema.ammPool.chainId, chainId))) {
    const fee = Number((await context.client.readContract({ address: pool.pool, abi: clPoolAbi, functionName: "fee" })) as number);
    if (fee !== pool.feePips) await context.db.update(schema.ammPool, { chainId, pool: pool.pool }).set({ feePips: fee, lastBlock: blockNumber });
  }
});
