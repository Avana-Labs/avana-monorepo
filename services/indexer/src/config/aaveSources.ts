// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The Ponder contract names Aave V4 Hubs and Spokes, vault tokens and loss layers are indexed under. One contract can
// match several sources (a manifest Spoke is also announced by its Hub's `AddSpoke`), so every handler registers on
// each name, records the log once under the contract's own kind (`AaveSpoke.<Event>`, `FirstLossReserve.<Event>`) and
// acts only on the first delivery (`recordLog(...).fresh`).

/**
 * - `AaveSpoke`: the manifest's Lend and CDP Spokes, from their deployment blocks.
 * - `AaveSpokeAdded`: every Spoke a manifest Hub adds with `AddSpoke`, so a Lend or CDP Spoke added later is followed.
 */
export const AAVE_SPOKE_SOURCES = ["AaveSpoke", "AaveSpokeAdded"] as const;

/** `AaveHub`: the manifest's Hubs, from their deployment blocks. */
export const AAVE_HUB_SOURCES = ["AaveHub"] as const;

/**
 * - `FirstLossReserveListed`: the First-Loss Reserves and DAO deficit offsets the manifest lists, from their deployment
 *   blocks, so a reserve funded before a RiskModule registers it has its funding indexed.
 * - `FirstLossReserve`: every First-Loss Reserve a RiskModule registers for a debt reserve (`DebtReserveSet`).
 * - `DaoDeficitOffset`: every Spoke a manifest Hub adds, decoded with the First-Loss Reserve ABI, so a deficit offset the
 *   Aave DAO registers on a Hub later is followed. Other Spokes emit none of these events.
 */
export const FIRST_LOSS_SOURCES = ["FirstLossReserveListed", "FirstLossReserve", "DaoDeficitOffset"] as const;

/** `VaultTokenListed`: the manifest's vault tokens. `VaultToken`: every one a RiskModule activates. */
export const VAULT_TOKEN_SOURCES = ["VaultTokenListed", "VaultToken"] as const;
