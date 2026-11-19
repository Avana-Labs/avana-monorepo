// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "../../custody/lp-vault/ILPVault.sol";

/// @title IUniswapV3Integration
/// @notice The Uniswap v3 LPVault: custody of canonical NonfungiblePositionManager positions, keyed by
/// `bytes32(tokenId)`; a pool is named by its address as a word.
interface IUniswapV3Integration is ILPVault {
    /// @notice Returns the canonical Uniswap v3 NonfungiblePositionManager.
    function NFPM() external view returns (address nfpm);

    /// @notice Returns the canonical Uniswap v3 factory.
    function FACTORY() external view returns (address factory);
}
