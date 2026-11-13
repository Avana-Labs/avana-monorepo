// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The immutable logic contracts of one LPOracle implementation, each run by delegatecall in the market proxy's
/// storage (2.10 Upgrade rules).
/// @dev `initLogic` runs `initialize`'s market part and `listingLogic` runs `checkConfig`; an implementation whose two
/// fit one contract passes the same address for both. Every logic contract must report the implementation's chain
/// constants (`logicConfig`).
/// @custom:spec REQ-ORACLE-080, REQ-ORACLE-106
// The struct's name keeps its LPOracle prefix, as every LPOracle type does.
// forge-lint: disable-next-item(pascal-case-struct)
struct LPOracleLogicSet {
    // Poke logic contract.
    address pokeLogic;
    // Initialization logic contract (`initializeMarket`).
    address initLogic;
    // Listing logic contract (`checkConfig`).
    address listingLogic;
    // View logic contract.
    address viewLogic;
}
