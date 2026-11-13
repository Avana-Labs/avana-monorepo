// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The three logic contracts the LPVaultSwap implementation delegatecalls, each an implementation immutable.
/// @custom:spec REQ-SWAP-040
// The contract's name keeps its LPVaultSwap prefix, as every LPVaultSwap type does.
// forge-lint: disable-next-item(pascal-case-struct)
struct LPVaultSwapLogics {
    // Body of `liquidate`.
    address liquidation;
    // Body of `settlePending`.
    address pending;
    // Bodies of `deleverage` and `onFlashLoan`.
    address deleverage;
}
