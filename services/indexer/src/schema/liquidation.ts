// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Liquidations, repayments with collateral and First-Loss cover.

import { index, onchainTable, primaryKey } from "ponder";

/**
 * One row per `LiquidationModule.Liquidated`: the debt repaid, the units seized, the floor credit unwound and the pool
 * tokens paid to the liquidator. `FeePaid` of the same liquidation (emitted right after) adds the Avana fee; a
 * `FlashLiquidator.FlashLiquidated` of the same transaction adds the flash loan, premium, top-up and profit.
 */
export const liquidation = onchainTable(
  "liquidation",
  (t) => ({
    chainId: t.integer().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
    blockNumber: t.bigint().notNull(),
    blockHash: t.hex().notNull(),
    liquidationModule: t.hex().notNull(),
    account: t.hex().notNull(),
    /** The LiquidationModule's integration; with `marketId`, the liquidated market. */
    integrationId: t.integer().notNull(),
    marketId: t.bigint().notNull(),
    liquidator: t.hex().notNull(),
    debtReserveId: t.bigint().notNull(),
    debtRepaid: t.bigint().notNull(),
    seized: t.bigint().notNull(),
    creditUnwound: t.bigint().notNull(),
    amount0: t.bigint().notNull(),
    amount1: t.bigint().notNull(),
    feeUnits: t.bigint().notNull(),
    fee0: t.bigint().notNull(),
    fee1: t.bigint().notNull(),
    /** Set when a FlashLiquidator ran it. */
    flashAmount: t.bigint(),
    flashPremium: t.bigint(),
    topUp: t.bigint(),
    profit: t.bigint(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.chainId, table.txHash, table.logIndex] }),
    accountIdx: index().on(table.chainId, table.account),
    marketIdx: index().on(table.chainId, table.integrationId, table.marketId, table.blockNumber),
    txIdx: index().on(table.chainId, table.txHash),
  }),
);

/**
 * The latest `Liquidated` of each (transaction, account, market): the row its `FeePaid` and `FlashLiquidated`, later
 * logs of the same transaction, complete.
 */
export const liquidationInTx = onchainTable(
  "liquidation_in_tx",
  (t) => ({
    chainId: t.integer().notNull(),
    txHash: t.hex().notNull(),
    account: t.hex().notNull(),
    integrationId: t.integer().notNull(),
    marketId: t.bigint().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.txHash, table.account, table.integrationId, table.marketId] }) }),
);

/** One row per `FlashloanRepay.RepaidWithCollateral`: part or all of a debt repaid from a position's liquidity. */
export const collateralRepay = onchainTable(
  "collateral_repay",
  (t) => ({
    chainId: t.integer().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
    blockNumber: t.bigint().notNull(),
    flashloanRepay: t.hex().notNull(),
    wallet: t.hex().notNull(),
    positionKey: t.hex().notNull(),
    asset: t.hex().notNull(),
    repaid: t.bigint().notNull(),
    premium: t.bigint().notNull(),
    liquidity: t.bigint().notNull(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.chainId, table.txHash, table.logIndex] }),
    walletIdx: index().on(table.chainId, table.wallet),
  }),
);

/** One row per `DeficitCovered` of a First-Loss Reserve or DAO deficit offset: a Spoke's deficit the layer absorbed. */
export const firstLossCover = onchainTable(
  "first_loss_cover",
  (t) => ({
    chainId: t.integer().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
    blockNumber: t.bigint().notNull(),
    firstLossReserve: t.hex().notNull(),
    spoke: t.hex().notNull(),
    caller: t.hex().notNull(),
    covered: t.bigint().notNull(),
    shares: t.bigint().notNull(),
    balanceAfter: t.bigint().notNull(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.chainId, table.txHash, table.logIndex] }),
    reserveIdx: index().on(table.chainId, table.firstLossReserve, table.blockNumber),
  }),
);

/** The RiskModules' keeper registry: the liquidation bots whose registration lets borrowing run. */
export const keeper = onchainTable(
  "keeper",
  (t) => ({
    chainId: t.integer().notNull(),
    riskModule: t.hex().notNull(),
    keeper: t.hex().notNull(),
    active: t.boolean().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.riskModule, table.keeper] }) }),
);
