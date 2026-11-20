// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title AaveAdapterStorage
/// @notice The AaveAdapter's state: one account per wallet and market.
abstract contract AaveAdapterStorage {
    /// @dev The deployed account of each wallet in each market; zero before its first pledge.
    mapping(address wallet => mapping(uint256 marketId => address account)) internal _accounts;
}
