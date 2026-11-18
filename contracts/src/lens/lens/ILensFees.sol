// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionFeesView} from "./types/PositionFeesView.sol";

/// @title ILensFees
/// @notice Uncollected fees of pledged positions, computed from the pool's fee growth.
interface ILensFees {
    /// @notice Returns what `collectFees` would pay for one position of a market in this block.
    /// @dev Returns `supported = false` and zero amounts for an unsupported protocol or a position outside the pool.
    /// @param positionKey The position, in the market's AMM integration key format.
    function getPositionFees(
        uint256 marketId,
        bytes32 positionKey
    ) external view returns (PositionFeesView memory fees);

    /// @notice Returns `getPositionFees` for every record of a wallet's account in a market, in seizure-list order.
    /// @return fees One entry per record; empty before the proxy is deployed.
    function getAccountFees(
        address wallet,
        uint256 marketId
    ) external view returns (PositionFeesView[] memory fees);
}
