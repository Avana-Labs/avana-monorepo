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
