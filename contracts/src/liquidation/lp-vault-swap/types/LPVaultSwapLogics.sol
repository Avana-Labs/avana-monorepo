// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The three logic contracts the LPVaultSwap implementation delegatecalls, each an implementation immutable.
// forge-lint: disable-next-item(pascal-case-struct)
struct LPVaultSwapLogics {
    address liquidation;
    address pending;
    address deleverage;
}
