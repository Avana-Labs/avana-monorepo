// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The per-chain addresses and the keeper floor every LPVaultSwap implementation and logic contract is built
/// with; the implementation checks that each logic contract carries the same values (`logicConfig`).
/// @dev None of the addresses needs code at deployment: each is a CREATE3-predicted fixed address.
/// @custom:spec REQ-SWAP-002, REQ-SWAP-034, REQ-SWAP-040, REQ-SWAP-047
// The contract's name keeps its LPVaultSwap prefix, as every LPVaultSwap type does.
// forge-lint: disable-next-item(pascal-case-struct)
struct LPVaultSwapImmutables {
    // The chain's Lock (LPVaultSwap is one of its two members).
    address lock;
    // The chain's AaveAdapter fixed proxy address.
    address aaveAdapter;
    // The chain's Collateralization ledger.
    address collateralization;
    // The MarketRegistry fixed proxy address.
    address marketRegistry;
    // The ParameterStore fixed proxy address.
    address parameterStore;
    // The PayoutEscrow.
    address payoutEscrow;
    // keeperFloor: fewest active committed operators removeKeeper leaves (1 at launch).
    uint256 keeperFloor;
}
