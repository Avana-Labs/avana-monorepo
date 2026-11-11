// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "../custody/lp-vault/ILPVault.sol";
import {ClMarketConfig} from "./types/ClMarketConfig.sol";

/// @title IClIntegration
/// @notice Shared extension of the concentrated-liquidity LPVaults (Uniswap v3 on Ethereum, Aerodrome Slipstream on
/// Base): NFT positions, exact tick ranges and the v3 liquidity math.
/// @dev `positionKey` encodes the NFT: `bytes32(tokenId)` for Uniswap v3, and for Slipstream
/// `bytes32((uint256(generation) << 248) | tokenId)` with `tokenId < 2^248`. Units are position liquidity `L`
/// (vault-token base units, multiplier 1), bounded by `type(uint120).max`. Composition:
/// `sO = isqrt(mulDiv(num, 2^192, den))` from the oracle prices, clamped to `[sqrtRatioAtTick(tickLower),
/// sqrtRatioAtTick(tickUpper)]`, then `(a0, a1) = getAmountsForLiquidity(sO, sa, sb, L)` floored, each reduced by 1 raw
/// unit when positive. Uncollected fees (`tokensOwed`, fee growth) never enter the value. The NFT is pulled with
/// `transferFrom`, never `safeTransferFrom`; an NFT that arrives through `safeTransferFrom` is stray.
/// @custom:spec REQ-AMM-V3-001, REQ-AMM-V3-003, REQ-AMM-V3-004, REQ-AMM-SLIP-001, REQ-AMM-SLIP-003, Q-370, Q-371
interface IClIntegration is ILPVault {
    /// @notice Returns the market's concentrated-liquidity configuration.
    /// @dev Reverts with `MarketBinding` for a market not bound to this integration.
    /// @custom:spec REQ-AMM-V3-002, REQ-AMM-SLIP-002
    function clMarket(
        uint256 marketId
    ) external view returns (ClMarketConfig memory config);

    /// @notice Returns the oracle sqrt price of a market before and after the clamp to its range.
    /// @dev `sqrtOracleX96 = isqrt(mulDiv(p0 * 10^d1, 2^192, p1 * 10^d0))`, floored (Q64.96); `sqrtUsedX96` is it clamped
    /// to the range. Example: range [-100, 100], USDC/USDT at (1.0000e8, 0.9800e8): the oracle tick is about 202, above
    /// the range, so the clamp sets `sqrtUsedX96 = sqrtRatioAtTick(100)` and the position is valued entirely as token1,
    /// which is what a position above its range holds (AMMN-RT-02).
    /// @custom:spec REQ-AMM-V3-005, REQ-AMM-SLIP-005
    function oracleSqrtPrice(
        uint256 marketId,
        uint256[] calldata prices
    ) external view returns (uint160 sqrtOracleX96, uint160 sqrtUsedX96, bool clamped);

    /// @notice Returns the NFT token ID of a position key.
    /// @custom:spec REQ-AMM-V3-001, REQ-AMM-SLIP-001
    function tokenIdOf(
        bytes32 positionKey
    ) external pure returns (uint256 tokenId);

    /// @notice Accepts an NFT from a bound position manager's `safeTransferFrom` as stray.
    /// @dev Reverts with `UnsupportedNft` unless `msg.sender` is a position manager bound to this integration.
    /// Records nothing, does not acquire the lock, emits `StrayReceived` and returns the ERC-721 receiver selector.
    /// @custom:spec REQ-VAULT-078, REQ-VAULT-093, REQ-VAULT-124
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4 selector);
}
