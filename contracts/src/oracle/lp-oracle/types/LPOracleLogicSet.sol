// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The immutable logic contracts of one LPOracle implementation, each run by delegatecall.
/// @dev `initLogic` and `listingLogic` may be the same address.
// The struct's name keeps its LPOracle prefix, as every LPOracle type does.
// forge-lint: disable-next-item(pascal-case-struct)
struct LPOracleLogicSet {
    address pokeLogic;
    // Runs `initializeMarket`.
    address initLogic;
    // Runs `checkConfig`.
    address listingLogic;
    address viewLogic;
}
