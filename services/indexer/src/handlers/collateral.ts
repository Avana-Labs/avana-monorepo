// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// LPVault custody: each pledged position and the pledge and withdrawal totals of its market (a pool's Full range and
// Custom range markets apart), and the mints and burns of every vault token.

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { zeroAddress } from "viem";
import { VAULT_TOKEN_SOURCES } from "../config/aaveSources.ts";
import { logOnly } from "../lib/logOnly.ts";
import { recordLog } from "../lib/record.ts";

type Ctx = Parameters<typeof recordLog>[1];
type Totals = { positions?: number; liquidity?: bigint; credit?: bigint; pledges?: number; withdrawals?: number; unwinds?: number };

/** Adds the deltas to the market's totals. */
async function moveMarket(context: Ctx, chainId: number, marketId: bigint, block: bigint, d: Totals) {
  await context.db
    .insert(schema.marketCollateral)
    .values({
      chainId,
      marketId,
      positions: d.positions ?? 0,
      liquidity: d.liquidity ?? 0n,
      credit: d.credit ?? 0n,
      pledges: d.pledges ?? 0,
      withdrawals: d.withdrawals ?? 0,
      unwinds: d.unwinds ?? 0,
      lastBlock: block,
    })
    .onConflictDoUpdate((row) => ({
      positions: row.positions + (d.positions ?? 0),
      liquidity: row.liquidity + (d.liquidity ?? 0n),
      credit: row.credit + (d.credit ?? 0n),
      pledges: row.pledges + (d.pledges ?? 0),
      withdrawals: row.withdrawals + (d.withdrawals ?? 0),
      unwinds: row.unwinds + (d.unwinds ?? 0),
      lastBlock: block,
    }));
}

ponder.on("LPVault:PositionPledged", async ({ event, context }) => {
  const p = await recordLog(event, context, "LPVault.PositionPledged");
  // A replayed log must not count the pledge twice.
  if (!p.fresh) return;
  const a = event.args;
  const stamp = { lastBlock: p.blockNumber, lastBlockHash: p.blockHash, lastLogIndex: p.logIndex };
  const row = { marketId: a.marketId, account: a.account, wallet: zeroAddress, liquidity: a.liquidity, credit: a.credit, held: true, pledgedBlock: p.blockNumber, ...stamp };
  await context.db
    .insert(schema.position)
    .values({ chainId: p.chainId, lpVault: event.log.address, positionKey: a.positionKey, ...row })
    .onConflictDoUpdate(row);
  await moveMarket(context, p.chainId, a.marketId, p.blockNumber, { positions: 1, liquidity: a.liquidity, credit: a.credit, pledges: 1 });
});

type Moved = { liquidity: bigint; credit: bigint };

/** A change to a held position: `dl` liquidity and `dc` credit (negative to remove), and its market's totals. */
function positionChange(kind: string, delta: (a: Moved) => { dl: bigint; dc: bigint; release?: boolean; count?: Totals }) {
  ponder.on(`LPVault:${kind}` as Parameters<typeof ponder.on>[0], async ({ event, context }: any) => {
    const p = await recordLog(event, context, `LPVault.${kind}`);
    if (!p.fresh) return;
    const key = { chainId: p.chainId, lpVault: event.log.address, positionKey: event.args.positionKey as `0x${string}` };
    const row = await context.db.find(schema.position, key);
    // Every change follows the position's PositionPledged; a missing one stops the indexer (fail closed).
    if (!row) throw new Error(`LPVault.${kind} for position ${key.positionKey} on chain ${p.chainId} before its PositionPledged`);
    const d = delta(event.args as Moved);
    const stamp = { lastBlock: p.blockNumber, lastBlockHash: p.blockHash, lastLogIndex: p.logIndex };
    await context.db
      .update(schema.position, key)
      .set({ liquidity: row.liquidity + d.dl, credit: row.credit + d.dc, ...(d.release ? { held: false } : {}), ...stamp });
    await moveMarket(context, p.chainId, row.marketId, p.blockNumber, { liquidity: d.dl, credit: d.dc, ...(d.release ? { positions: -1 } : {}), ...d.count });
  });
}

positionChange("LiquidityAdded", (a: Moved) => ({ dl: a.liquidity, dc: a.credit }));
positionChange("LiquidityRemoved", (a: Moved) => ({ dl: 0n - a.liquidity, dc: 0n - a.credit, count: { withdrawals: 1 } }));
positionChange("PositionReleased", (a: Moved) => ({ dl: 0n - a.liquidity, dc: 0n - a.credit, release: true, count: { withdrawals: 1 } }));
positionChange("PositionUnwound", (a: Moved) => ({ dl: 0n - a.liquidity, dc: 0n - a.credit, count: { unwinds: 1 } }));

logOnly("LPVault", ["MarketListed", "FeesCollected", "FeesHeld"]);

// Vault-token mints (Transfer from zero) and burns (Transfer to zero); other transfers, only to and from account
// proxies and the LiquidationModule, are logged.
for (const source of VAULT_TOKEN_SOURCES) {
  ponder.on(`${source}:Transfer`, async ({ event, context }) => {
    const p = await recordLog(event, context, "VaultToken.Transfer");
    if (!p.fresh) return;
    const { from, to, value } = event.args;
    const mint = from === zeroAddress ? value : 0n;
    const burn = to === zeroAddress ? value : 0n;
    if (mint === 0n && burn === 0n) return;
    await context.db
      .insert(schema.vaultTokenSupply)
      .values({ chainId: p.chainId, vaultToken: event.log.address, supply: mint - burn, minted: mint, burned: burn, lastBlock: p.blockNumber })
      .onConflictDoUpdate((row) => ({ supply: row.supply + mint - burn, minted: row.minted + mint, burned: row.burned + burn, lastBlock: p.blockNumber }));
  });
  logOnly(source, ["Approval", "ProxyAdded"], "VaultToken");
}
