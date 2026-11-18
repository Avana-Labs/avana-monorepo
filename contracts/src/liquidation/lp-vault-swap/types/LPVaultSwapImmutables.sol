// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Per-chain addresses and keeper floor every LPVaultSwap implementation and logic contract is built with.
// forge-lint: disable-next-item(pascal-case-struct)
struct LPVaultSwapImmutables {
    address lock;
    address aaveAdapter;
    address collateralization;
    address marketRegistry;
    address parameterStore;
    address payoutEscrow;
    // Fewest active committed operators removeKeeper leaves.
    uint256 keeperFloor;
}
