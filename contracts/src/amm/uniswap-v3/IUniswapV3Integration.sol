// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IClIntegration} from "../IClIntegration.sol";

/// @title IUniswapV3Integration
/// @notice The Uniswap v3 LPVault on Ethereum: custody of canonical NonfungiblePositionManager positions in exact-range
/// markets.
/// @dev `positionKey = bytes32(tokenId)`. A position matches a market only when `NFPM.positions(tokenId)` returns the
/// market's `token0`, `token1` and `fee`, `FACTORY.getPool(token0, token1, fee) == market pool`, and `tickLower`,
/// `tickUpper` equal the market's range exactly. `slot0()` has seven fields; `unlocked` is the reentrancy check.
/// The consistency check reads `observe([W, 0])` and requires the pool's observation cardinality to cover `W` at the
/// chain's block interval `BLOCK_TIME` (`ceil(W / BLOCK_TIME) + 1`: 151 observations for W = 1,800 s at 12 s on
/// Ethereum, 901 at 2 s on Base).
/// @custom:spec REQ-AMM-V3-001, REQ-AMM-V3-002, REQ-AMM-V3-003, REQ-AMM-V3-004, REQ-AMM-V3-005, REQ-AMM-V3-012, Q-371
interface IUniswapV3Integration is IClIntegration {
    /// @notice Returns the canonical Uniswap v3 NonfungiblePositionManager.
    /// @return nfpm Constructor immutable.
    /// @custom:spec REQ-AMM-V3-001, REQ-VAULT-155
    function NFPM() external view returns (address nfpm);

    /// @notice Returns the canonical Uniswap v3 factory.
    /// @return factory Constructor immutable.
    /// @custom:spec REQ-AMM-V3-002
    function FACTORY() external view returns (address factory);

    /// @notice Returns the chain's minimum block interval the TWAP observation check sizes the buffer with.
    /// @return blockTime Constructor immutable, seconds (12 on Ethereum, 2 on Base).
    /// @custom:spec REQ-AMM-V3-012, SPEC-ORC-022
    function BLOCK_TIME() external view returns (uint256 blockTime);
}
