// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DrawHeadroom} from "../lens/lens/types/DrawHeadroom.sol";

/// @notice Avana and Aave cap headroom for a market and depositor.
/// @dev Rounding never overstates headroom.
struct CapView {
    uint256 blockNumber;
    uint256 timestamp;
    address hub;
    address vaultToken;
    address depositor;
    uint256 minPledgeUsd;
    uint256 marketHeadroomUsd;
    uint256 sliceHeadroomUsd;
    address[] tokens;
    uint256[] tokenHeadroomUsd;
    uint256 poolShareBps;
    uint256 poolShareMaxBps;
    uint256 chargePricePerWholeToken;
    uint256 vaultTokenAddHeadroom;
    DrawHeadroom[] drawHeadroom;
}
