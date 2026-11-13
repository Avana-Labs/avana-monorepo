// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {LPOracleCLModule} from "../../../src/oracle/lp-oracle/LPOracleCLModule.sol";
import {LPOracleCLPool} from "../../../src/oracle/lp-oracle/LPOracleCLPool.sol";
import {LPOracleStorage} from "../../../src/oracle/lp-oracle/LPOracleStorage.sol";

/// @title LPOracleCLMathHarness
/// @notice Exposes the concentrated-liquidity module's pure and storage-only computations (the composition at the
/// clamped oracle price, the oracle square-root price, the clamp flag, the mean tick of two cumulatives, the TWAP quote
/// of a tick, the shock check and the tick distance) on chosen token decimals and range, for the Halmos and fuzz
/// suites. The pool reads are covered on real Uniswap v3 pools by the unit suites.
contract LPOracleCLMathHarness is LPOracleCLModule {
    constructor() LPOracleStorage(address(0x7173), 12, 900_000, 3_000_000, false) LPOracleCLPool(7) {}

    function setMarket(
        uint8 d0,
        uint8 d1,
        int24 tickLower,
        int24 tickUpper
    ) external {
        Layout storage $ = _s();
        delete $.tokenDecimals;
        $.tokenDecimals.push(d0);
        $.tokenDecimals.push(d1);
        ClLayout storage c = _cl();
        (c.tickLower, c.tickUpper) = (tickLower, tickUpper);
        (c.sqrtLower, c.sqrtUpper) = (ClPriceMath.sqrtRatioAtTick(tickLower), ClPriceMath.sqrtRatioAtTick(tickUpper));
    }

    function composition(
        uint256 units,
        uint256 p0,
        uint256 p1
    ) external view returns (bool ok, uint256 a0, uint256 a1) {
        uint256[] memory prices = new uint256[](2);
        (prices[0], prices[1]) = (p0, p1);
        uint256[] memory amounts;
        (ok, amounts) = _composition(units, prices);
        if (ok) (a0, a1) = (amounts[0], amounts[1]);
    }

    function oracleSqrt(
        uint256 p0,
        uint256 p1
    ) external view returns (uint160) {
        uint256[] memory prices = new uint256[](2);
        (prices[0], prices[1]) = (p0, p1);
        return _oracleSqrt(prices);
    }

    function clampedAt(
        uint256 p0,
        uint256 p1
    ) external view returns (bool) {
        uint256[] memory prices = new uint256[](2);
        (prices[0], prices[1]) = (p0, p1);
        return _clampedAt(prices);
    }

    function meanOf(
        int256 c0,
        int256 c1,
        uint32 window
    ) external pure returns (bool ok, int24 tick) {
        return _meanOf(c0, c1, window);
    }

    function quoteAtTick(
        int24 tick,
        uint256 baseAmount,
        bool baseIsToken0
    ) external pure returns (uint256) {
        return _quoteAtTick(tick, baseAmount, baseIsToken0);
    }

    function shockSqrtHolds(
        uint256 q0,
        uint256 q1
    ) external view returns (bool) {
        uint256[] memory quotes = new uint256[](2);
        (quotes[0], quotes[1]) = (q0, q1);
        return _shockSqrtHolds(quotes);
    }

    function tickDistance(
        int24 a,
        int24 b
    ) external pure returns (uint256) {
        return _tickDistance(a, b);
    }
}
