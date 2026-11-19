// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "./ILPVault.sol";

/// @title LPVaultStorage
/// @notice State of the LPVault.
abstract contract LPVaultStorage {
    /// @dev Band markets by ID; `pool == 0` means not listed.
    mapping(uint256 marketId => ILPVault.Market market) internal _markets;
    /// @dev The band market of a pool; 0 when none.
    mapping(bytes32 pool => uint256 marketId) internal _marketOfPool;
    /// @dev Position records; `account == address(0)` means no record.
    mapping(bytes32 positionKey => ILPVault.Position position) internal _positions;
    /// @dev Open positions of each account, at most `MAX_POSITIONS`.
    mapping(address account => bytes32[] positionKeys) internal _accountPositions;
    /// @dev Fees an AMM paid out with a liquidity removal, kept for the position until collected.
    mapping(bytes32 positionKey => uint256[2] amounts) internal _heldFees;
}
