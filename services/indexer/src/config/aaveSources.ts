// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The Ponder contract names Aave V4 Hubs and Spokes are indexed under. One Hub or Spoke can match several sources (a
// manifest Spoke is also announced by its Hub's `AddSpoke`), so every handler registers on each name, records the log
// once under the Aave contract's own kind (`AaveSpoke.<Event>`, `AaveHub.<Event>`) and acts only on the first
// delivery (`recordLog(...).fresh`).

/**
 * - `AaveSpoke`: the manifest's Lend and CDP Spokes, from their deployment blocks.
 * - `AaveSpokeAdded`: every Spoke a manifest Hub adds with `AddSpoke`, so a Lend or CDP Spoke added later is followed.
 * - `AaveSpokeApproved`: every CDP Spoke the MarketRegistry approves (`SpokeApproved`), on any Hub, a later one included.
 */
export const AAVE_SPOKE_SOURCES = ["AaveSpoke", "AaveSpokeAdded", "AaveSpokeApproved"] as const;

/**
 * - `AaveHub`: the manifest's Hubs, from their deployment blocks.
 * - `AaveHubRecorded`: every Hub the MarketRegistry records (`HubRecorded`), so a Hub recorded later is followed.
 */
export const AAVE_HUB_SOURCES = ["AaveHub", "AaveHubRecorded"] as const;

/**
 * - `AvanaFirstLossReserveListed`: the First-Loss Reserves the manifest lists, from their deployment blocks, so a
 *   reserve funded before the MarketRegistry sets it (the release funds it first) has its funding indexed.
 * - `AvanaFirstLossReserve`: every First-Loss Reserve the MarketRegistry sets (`AvanaFirstLossReserveSet`), from that
 *   event on, so a reserve set after the manifest is followed.
 * - `DaoDeficitOffset`: every Spoke a manifest Hub adds (`AddSpoke`), decoded with the First-Loss Reserve ABI, so the Aave
 *   DAO's deficit offset of a (Hub, asset), a First-Loss Reserve the DAO deploys and registers on the Hub, is followed
 *   from its registration. Avana's own reserves are Hub Spokes too and match both sources; other Spokes emit none of
 *   these events. A log several sources match is recorded once. Logs are recorded under `AvanaFirstLossReserve.<Event>` with the emitting contract's address.
 */
export const FIRST_LOSS_SOURCES = ["AvanaFirstLossReserveListed", "AvanaFirstLossReserve", "DaoDeficitOffset"] as const;
