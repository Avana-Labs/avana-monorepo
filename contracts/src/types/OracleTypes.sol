// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceInput} from "../lens/lens/types/LensTypes.sol";

/// @notice Price state of one market's LPOracle feed or one debt asset's DebtOracle, ordered by severity.
enum PriceState {
    Live,
    Drifting,
    Cached,
    Expired
}

/// @notice Price state report of one market.
struct PriceView {
    uint256 blockNumber;
    uint256 timestamp;
    address vaultToken;
    address feed;
    PriceState state;
    PriceState liquidationState;
    uint256 reasons;
    uint256 price;
    uint256 acceptedPrice;
    uint256 acceptedAt;
    PriceInput[] inputs;
    uint256[] tokenDeviationBps;
    uint256 disagreeSince;
    bool disagreementPauseActive;
    bool disagreementExpired;
    uint256 recoveredAt;
    uint256 graceEndsAt;
    bool borrowAllowed;
}
