// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModule} from "../interfaces/IRiskModule.sol";

/// @title RiskModuleStorage
/// @notice The RiskModule's state: markets, Spokes, widths, debt reserves, coverage, fee and keepers.
abstract contract RiskModuleStorage {
    // The variables are read and written by the contract that inherits this storage layout, not here.
    // forge-lint: disable-start(unused-state-variables)
    /// @dev Markets by ID; the ID is also the LPVault market ID.
    mapping(uint256 marketId => IRiskModule.Market) internal _markets;
    /// @dev The latest pair of markets of each pool.
    mapping(bytes32 pool => IRiskModule.PoolMarkets) internal _poolMarkets;
    /// @dev Registered CDP Spokes.
    mapping(address spoke => IRiskModule.SpokeConfig) internal _spokes;
    /// @dev Default Custom range width per Spoke kind.
    mapping(IRiskModule.SpokeKind kind => IRiskModule.Width) internal _widths;
    /// @dev Registered debt reserves.
    mapping(address spoke => mapping(uint256 reserveId => IRiskModule.DebtReserve)) internal _debtReserves;
    /// @dev Spokes whose draw caps of `(hub, asset)` the First-Loss Reserve covers; a Spoke has one reserve per pair.
    mapping(address hub => mapping(address asset => address[])) internal _coverageSpokes;
    /// @dev The First-Loss Reserve of `(hub, asset)`.
    mapping(address hub => mapping(address asset => address)) internal _firstLossReserveOf;
    /// @dev Keeper membership and list.
    mapping(address account => bool) internal _isKeeper;
    address[] internal _keepers;
    /// @dev The next market ID `listPool` assigns; starts at 1.
    uint256 internal _nextMarketId = 1;
    uint16 internal _coverageRatioBps;
    uint16 internal _feeShareBps;
    address internal _feeRecipient;
    // forge-lint: disable-end(unused-state-variables)
}
