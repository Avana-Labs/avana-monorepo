// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CapView} from "../../types/MarketTypes.sol";
import {PendingView} from "../../types/PositionTypes.sol";
import {BackingView} from "./types/BackingView.sol";
import {RecordBackingView} from "./types/RecordBackingView.sol";

/// @title ILensMarket
/// @notice Market views of the Lens: backing check, record backing, pending settlement and cap headroom.
interface ILensMarket {
    /// @notice Returns the market-level backing and Aave configuration check.
    function checkBacking(
        address vaultToken
    ) external view returns (BackingView memory backing);

    /// @notice Returns custody and live liquidity against credited units for one page of the market's open records.
    /// @dev Empty when `offset` is past the last record; same `limit` rules as `getRecords`.
    function checkRecordBacking(
        address vaultToken,
        uint256 offset,
        uint256 limit
    ) external view returns (RecordBackingView[] memory records);

    /// @notice Returns the market's pending-settlement balance and whether LPVaultSwap holds enough units to settle it.
    function getPendingSettlement(
        address vaultToken
    ) external view returns (PendingView memory pending);

    /// @notice Returns Avana USD cap headroom, `minPledgeUsd` and Aave cap headroom for a market and depositor.
    function getCapHeadroom(
        address vaultToken,
        address depositor
    ) external view returns (CapView memory caps);
}
