// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";

/// @title AccountProxy
/// @notice One wallet's Aave identity in one market. It holds no tokens and has no functions: the AaveAdapter that
/// deployed it is its Aave position manager and acts for it, and only for its wallet.
/// @dev Deployed by the AaveAdapter with CREATE2 (salt = wallet and market), so its address is known before the
/// first pledge. The Spoke must have the adapter active as a position manager.
contract AccountProxy {
    /// @notice The AaveAdapter, the only position manager this account approves.
    address public immutable ADAPTER;
    /// @notice The wallet this account belongs to.
    address public immutable OWNER;
    /// @notice The market this account holds.
    uint256 public immutable MARKET_ID;

    /// @notice Approves the deployer as this account's position manager on `spoke`.
    constructor(
        address spoke,
        address owner,
        uint256 marketId
    ) {
        (ADAPTER, OWNER, MARKET_ID) = (msg.sender, owner, marketId);
        IAaveV4Spoke(spoke).setUserPositionManager(msg.sender, true);
    }
}
