// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Pending-settlement balance of a market (Q-201).
/// @dev `units`: reconciled vault-token units not yet burned (held by LPVaultSwap); `amounts[i]`: raw principal of the
/// market's token i (market token order) held by Collateralization that backs those units, booked at the amount
/// received (measured by balance delta, at most the principal removed), paid to LPVaultSwap only by `settlePending`
/// while the supply leaves room for the settled units. `amounts.length` equals the market's token count.
/// @custom:spec REQ-VAULT-029, REQ-VAULT-061, REQ-VAULT-135, REQ-VAULT-137, SPEC-BACK-009, SPEC-BACK-012, Q-271, Q-370
struct Pending {
    uint256 units;
    uint256[] amounts;
}
