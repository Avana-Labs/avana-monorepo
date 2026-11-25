// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Positions held by the LPVaults and the totals of each market (Full range and Custom range apart), and the supply of
// each vault token.

import { index, onchainTable, primaryKey } from "ponder";

/**
 * One pledged position (an NFT the LPVault holds for an account), key `chainId + LPVault + positionKey`: its liquidity
 * and floor credit after the last event. Pledged on `PositionPledged`; `LiquidityAdded` and `LiquidityRemoved` move it;
 * a liquidation's `PositionUnwound` takes liquidity and credit out; `PositionReleased` returns the NFT.
 */
export const position = onchainTable(
  "position",
  (t) => ({
    chainId: t.integer().notNull(),
    lpVault: t.hex().notNull(),
    positionKey: t.hex().notNull(),
    /** The LPVault's integration; with `marketId`, the position's market. */
    integrationId: t.integer().notNull(),
    marketId: t.bigint().notNull(),
    /** The account proxy the position is pledged to. */
    account: t.hex().notNull(),
    /** The wallet that pledged it (`AaveAdapter.Pledged`); the zero address until that log is handled. */
    wallet: t.hex().notNull(),
    liquidity: t.bigint().notNull(),
    credit: t.bigint().notNull(),
    held: t.boolean().notNull(),
    pledgedBlock: t.bigint().notNull(),
    lastBlock: t.bigint().notNull(),
    lastBlockHash: t.hex().notNull(),
    lastLogIndex: t.integer().notNull(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.chainId, table.lpVault, table.positionKey] }),
    accountIdx: index().on(table.chainId, table.account),
    walletIdx: index().on(table.chainId, table.wallet),
    marketIdx: index().on(table.chainId, table.integrationId, table.marketId),
  }),
);

/**
 * Pledges and withdrawals per market: the positions held, their liquidity and floor credit, and the running counts of
 * pledges, withdrawals (a release or a partial removal) and liquidation unwinds. A pool's Full range and Custom range
 * markets are two rows.
 */
export const marketCollateral = onchainTable(
  "market_collateral",
  (t) => ({
    chainId: t.integer().notNull(),
    integrationId: t.integer().notNull(),
    marketId: t.bigint().notNull(),
    positions: t.integer().notNull(),
    liquidity: t.bigint().notNull(),
    credit: t.bigint().notNull(),
    pledges: t.integer().notNull(),
    withdrawals: t.integer().notNull(),
    unwinds: t.integer().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.integrationId, table.marketId] }) }),
);

/** Each vault token's supply from its mints (`Transfer` from zero) and burns (`Transfer` to zero). */
export const vaultTokenSupply = onchainTable(
  "vault_token_supply",
  (t) => ({
    chainId: t.integer().notNull(),
    vaultToken: t.hex().notNull(),
    supply: t.bigint().notNull(),
    minted: t.bigint().notNull(),
    burned: t.bigint().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.vaultToken] }) }),
);
