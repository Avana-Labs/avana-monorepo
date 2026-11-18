// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SettlementReport} from "../../types/SettlementReport.sol";

/// @title ILPVaultSwapEvents
/// @notice Events of LPVaultSwap. Value amounts are in base units of the debt asset.
interface ILPVaultSwapEvents {
    event LiquidationSettled(
        address indexed caller, address indexed proxy, uint256 indexed marketId, SettlementReport report
    );

    /// @notice Emitted when a liquidation's borrower surplus was paid to the borrower's wallet or escrowed for it.
    /// @param amount Surplus paid, less any part the First-Loss Reserve took.
    event BorrowerSurplusPaid(
        address indexed proxy, address indexed wallet, address indexed debtAsset, uint256 amount, bool escrowed
    );

    /// @notice Emitted when an underwater or deficit liquidation paid borrower surplus into the First-Loss Reserve.
    /// @param amount The part of the surplus the reserve took.
    /// @param shares The reserve's Hub shares `fund` reported.
    event DeficitSurplusFunded(
        address indexed proxy,
        address indexed firstLossReserve,
        address indexed debtAsset,
        uint256 amount,
        uint256 shares
    );

    /// @notice Emitted when `deleverage` took and repaid a flash loan of the debt asset.
    event FlashLoanUsed(
        uint256 indexed marketId, address indexed flashSource, address indexed asset, uint256 amount, uint256 premium
    );

    /// @notice Emitted when a primary swap-route call reverted and the backup was tried.
    event RouteFailed(uint256 indexed marketId, address indexed token, address route, bytes4 errorSelector);

    /// @notice Emitted when route residue or a dust leg was sent to the caller of `liquidate`, or escrowed for it.
    event ResidueReturned(address indexed caller, address indexed token, uint256 amount, bool escrowed);

    event KeeperAdded(address indexed keeper);

    event KeeperRemoved(address indexed keeper);

    /// @param minPending Floor `added` had to meet.
    /// @param routeUsed Swap route used per pool token: 0 none, 1 primary, 2 backup.
    /// @param funded `added` plus the prior carry passed to `fund`, or 0 when the amount was carried.
    /// @param carried The carry of the settlement asset after the call (0 after a funding).
    event PendingSettlementForwarded(
        address indexed caller,
        uint256 indexed marketId,
        address vaultToken,
        uint256 units,
        uint256[] amounts,
        address indexed debtAsset,
        uint256 added,
        uint256 minPending,
        address firstLossReserve,
        uint8[] routeUsed,
        uint256 funded,
        uint256 carried
    );

    event Deleveraged(
        address indexed proxy,
        uint256 indexed marketId,
        uint256 indexed debtReserveId,
        uint128 units,
        uint256 debtRepaid,
        uint256 recovered,
        uint256 flashPremium,
        uint256 debtAssetOut
    );
}
