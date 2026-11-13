// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Fee-growth state of a concentrated-liquidity pool stand-in: the two fee growth globals, each tick's
/// `feeGrowthOutside`, and v3-core's `Tick.getFeeGrowthInside` over them, ported line by line from
/// `dependencies/uniswap-v3-core-5ea68a7/contracts/libraries/Tick.sol` (0.7, so every subtraction wraps). Slipstream's
/// `CLPool` keeps the same two steps for unstaked liquidity.
abstract contract ClFeeGrowthPool {
    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;
    mapping(int24 => uint256[2]) internal _feeGrowthOutside;

    function setFeeGrowthGlobal(
        uint256 g0,
        uint256 g1
    ) external {
        (feeGrowthGlobal0X128, feeGrowthGlobal1X128) = (g0, g1);
    }

    function setFeeGrowthOutside(
        int24 tick_,
        uint256 o0,
        uint256 o1
    ) external {
        _feeGrowthOutside[tick_] = [o0, o1];
    }

    /// @notice v3-core `Tick.getFeeGrowthInside(lower, upper, tickCurrent, global0, global1)`.
    function feeGrowthInside(
        int24 tickLower,
        int24 tickUpper
    ) external view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        int24 tickCurrent = _currentTick();
        uint256[2] memory lower = _feeGrowthOutside[tickLower];
        uint256[2] memory upper = _feeGrowthOutside[tickUpper];
        unchecked {
            uint256 feeGrowthBelow0X128;
            uint256 feeGrowthBelow1X128;
            if (tickCurrent >= tickLower) {
                feeGrowthBelow0X128 = lower[0];
                feeGrowthBelow1X128 = lower[1];
            } else {
                feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lower[0];
                feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lower[1];
            }
            uint256 feeGrowthAbove0X128;
            uint256 feeGrowthAbove1X128;
            if (tickCurrent < tickUpper) {
                feeGrowthAbove0X128 = upper[0];
                feeGrowthAbove1X128 = upper[1];
            } else {
                feeGrowthAbove0X128 = feeGrowthGlobal0X128 - upper[0];
                feeGrowthAbove1X128 = feeGrowthGlobal1X128 - upper[1];
            }
            feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
            feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
        }
    }

    function _currentTick() internal view virtual returns (int24);
}

/// @notice Fee accounting of a position manager stand-in, ported from v3-periphery 24ccf01
/// `NonfungiblePositionManager`: `mint` snapshots `feeGrowthInside*LastX128`; `increaseLiquidity`,
/// `decreaseLiquidity` and `collect` (the latter only with liquidity) first add
/// `uint128(FullMath.mulDiv(feeGrowthInside − last, liquidity, Q128))` to `tokensOwed` (wrapping, as in 0.7) and move the
/// snapshot. Off until a suite calls `setTrackFees(true)`, so suites that never touch fee growth see the stand-in as
/// before. The stand-in funds what it credits by minting the pool tokens to itself.
abstract contract ClFeeTrackingNpm {
    uint256 internal constant Q128 = 1 << 128;

    bool public trackFees;
    mapping(uint256 => uint256[2]) internal _feeLast;

    function setTrackFees(
        bool on
    ) external {
        trackFees = on;
    }

    /// @dev Snapshot at mint.
    function _snapshotFees(
        uint256 tokenId
    ) internal {
        if (!trackFees) return;
        (address pool, int24 lower, int24 upper,) = _feePosition(tokenId);
        (uint256 i0, uint256 i1) = ClFeeGrowthPool(pool).feeGrowthInside(lower, upper);
        _feeLast[tokenId] = [i0, i1];
    }

    /// @dev The fee update before a liquidity change or a collect.
    function _updateFees(
        uint256 tokenId,
        bool onlyWithLiquidity
    ) internal {
        if (!trackFees) return;
        (address pool, int24 lower, int24 upper, uint128 liquidity) = _feePosition(tokenId);
        if (onlyWithLiquidity && liquidity == 0) return;
        (uint256 i0, uint256 i1) = ClFeeGrowthPool(pool).feeGrowthInside(lower, upper);
        uint128 g0;
        uint128 g1;
        unchecked {
            g0 = uint128(Math.mulDiv(i0 - _feeLast[tokenId][0], liquidity, Q128));
            g1 = uint128(Math.mulDiv(i1 - _feeLast[tokenId][1], liquidity, Q128));
        }
        _feeLast[tokenId] = [i0, i1];
        _creditFees(tokenId, g0, g1);
    }

    function _feePosition(
        uint256 tokenId
    ) internal view virtual returns (address pool, int24 lower, int24 upper, uint128 liquidity);

    function _creditFees(
        uint256 tokenId,
        uint128 amount0,
        uint128 amount1
    ) internal virtual;
}
