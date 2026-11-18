// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IClIntegration} from "../IClIntegration.sol";

/// @title IUniswapV3Integration
/// @notice The Uniswap v3 LPVault: custody of canonical NonfungiblePositionManager positions in exact-range markets,
/// keyed by `bytes32(tokenId)`.
interface IUniswapV3Integration is IClIntegration {
    /// @notice Returns the canonical Uniswap v3 NonfungiblePositionManager.
    function NFPM() external view returns (address nfpm);

    /// @notice Returns the canonical Uniswap v3 factory.
    function FACTORY() external view returns (address factory);

    /// @notice Returns the chain's minimum block interval in seconds, used to size the TWAP observation check.
    function BLOCK_TIME() external view returns (uint256 blockTime);
}
