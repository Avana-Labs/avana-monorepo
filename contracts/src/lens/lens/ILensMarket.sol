// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CapView} from "../../types/CapView.sol";
import {PendingView} from "../../types/PendingView.sol";
import {BackingView} from "./types/BackingView.sol";
import {RecordBackingView} from "./types/RecordBackingView.sol";

/// @title ILensMarket
/// @notice Market views of the Lens: the backing check, record backing, the pending-settlement balance and cap
/// headroom.
interface ILensMarket {
    /// @notice Returns the market-level backing and Aave configuration check.
    /// @dev Loops only over the Spokes registered for the asset on the Hub, never over records.
    /// @param vaultToken The market.
    /// @return backing Raw values and pass/fail flags.
    /// @custom:spec REQ-LENS-012, REQ-LENS-013, INV-001, INV-003
    function checkBacking(
        address vaultToken
    ) external view returns (BackingView memory backing);

    /// @notice Returns position custody and live liquidity against credited units for one page of the market's open
    /// records.
    /// @dev With `n = Collateralization.getMarketRecordCount(vaultToken)`: returns an empty array when `offset >= n`;
    /// otherwise walks index positions `offset` to `offset + min(limit, n - offset) - 1` of the market's open-record
    /// index, so no input overflows. Same `limit` rules as `getRecords`.
    /// @param vaultToken The market.
    /// @param offset First index position of the page.
    /// @param limit Largest number of records returned.
    /// @return records Open records of the market in the page.
    /// @custom:spec REQ-LENS-014, REQ-LENS-023, REQ-LENS-024, INV-002, Q-268
    function checkRecordBacking(
        address vaultToken,
        uint256 offset,
        uint256 limit
    ) external view returns (RecordBackingView[] memory records);

    /// @notice Returns the market's pending-settlement balance and whether LPVaultSwap holds enough units to settle it.
    /// @param vaultToken The market.
    /// @return pending Pending units, pool tokens, LPVaultSwap's units, settleability and value in the debt asset.
    /// @custom:spec REQ-LENS-026, Q-201, Q-236
    function getPendingSettlement(
        address vaultToken
    ) external view returns (PendingView memory pending);

    /// @notice Returns Avana USD cap headroom, `minPledgeUsd` and Aave cap headroom for a market and depositor.
    /// @dev The CDP Spoke is `vaultToken.spoke()`; `drawHeadroom` has one entry per approved debt reserve of it.
    /// @param vaultToken The market.
    /// @param depositor The depositor wallet.
    /// @return caps Headroom values.
    /// @custom:spec REQ-LENS-018, REQ-LENS-019, Q-230
    function getCapHeadroom(
        address vaultToken,
        address depositor
    ) external view returns (CapView memory caps);
}
