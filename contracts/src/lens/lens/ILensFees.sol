// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionFeesView} from "./types/PositionFeesView.sol";

/// @title ILensFees
/// @notice Uncollected fees of pledged positions, computed in the Lens from the pool's fee growth exactly as the
/// position manager updates them on `collect`.
interface ILensFees {
    /// @notice Returns what `collectFees` would pay for one position of a market in this block.
    /// @dev Uniswap v3 and Aerodrome Slipstream positions; any other AMM protocol, an AMM protocol whose fees roll into
    /// the position, or a position outside the market's pool returns `supported = false` and zero amounts.
    /// @param marketId The market.
    /// @param positionKey The position, in the market's AMM integration key format.
    /// @return fees The fees.
    /// @custom:spec REQ-LENS-050
    function getPositionFees(
        uint256 marketId,
        bytes32 positionKey
    ) external view returns (PositionFeesView memory fees);

    /// @notice Returns `getPositionFees` for every record of a wallet's account in a market, in seizure-list order.
    /// @param wallet The wallet.
    /// @param marketId The account's market.
    /// @return fees One entry per record; empty before the proxy is deployed.
    /// @custom:spec REQ-LENS-051
    function getAccountFees(
        address wallet,
        uint256 marketId
    ) external view returns (PositionFeesView[] memory fees);
}
