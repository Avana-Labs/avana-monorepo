// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {IUniswapV3Pool} from "../../src/interfaces/external/uniswap/IUniswapV3Pool.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {ILPOracleErrors} from "../../src/oracle/lp-oracle/ILPOracleErrors.sol";
import {LPOracleCodes} from "../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {ClPriceStateView} from "../../src/oracle/lp-oracle/types/ClPriceStateView.sol";
import {InitParams} from "../../src/oracle/lp-oracle/types/InitParams.sol";
import {LPOracleV4Fixture} from "../utils/fixtures/LPOracleV4Fixture.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title LPOracleV4FuzzTest
/// @notice Fuzzed market encodings and consistency reads of the Uniswap v4 LPOracle module. Any change to one word of
/// the ten-word market, and any other length, either initializes or reverts `MarketMismatch(marketId)`, never another
/// error, and a word outside its range is never accepted. For any spot move of the v4 pool and any oracle price, the
/// reported deviation is the larger of `|spot - tickRef|` and `|referenceTwap - tickRef|`, recomputed here from the
/// PoolManager's `slot0` and the reference pool's `observe`, and the consistency reason is set exactly when it exceeds
/// the tolerance.
/// forge-config: default.isolate = false
contract LPOracleV4FuzzTest is LPOracleV4Fixture {
    uint256 internal constant WORDS = 10;

    function setUp() public {
        _deployV4Market();
    }

    // TEST-331 verifies: REQ-ORACLE-058, REQ-AMM-V4-001, REQ-AMM-V4-007
    function testFuzz_TEST_331_anyMarketWordIsAcceptedOrRefusedCleanly(
        uint256 i,
        uint256 value
    ) public {
        i = bound(i, 0, WORDS - 1);
        bytes memory m = _market(_v4Key(), address(ref));
        assembly {
            mstore(add(m, add(32, mul(i, 32))), value)
        }
        if (!_initializes(m)) return;
        assertTrue(_inRange(i, value), "a word outside its range was accepted");
    }

    // TEST-331 verifies: REQ-ORACLE-058
    function testFuzz_TEST_331_anyOtherLengthIsRefused(
        uint256 len
    ) public {
        len = bound(len, 0, 2 * WORDS * 32);
        vm.assume(len != WORDS * 32);
        bytes memory valid = _market(_v4Key(), address(ref));
        bytes memory m = new bytes(len);
        for (uint256 j = 0; j < len && j < valid.length; ++j) {
            m[j] = valid[j];
        }
        assertFalse(_initializes(m), "a market of another length was accepted");
    }

    // TEST-343 verifies: SPEC-AMM-V4-002, REQ-AMM-V4-005, REQ-ORACLE-104
    function testFuzz_TEST_343_deviationIsTheLargerOfSpotAndTwapDistance(
        int256 spotShift,
        uint256 priceBps
    ) public {
        (, int24 start) = _slot0V4(key);
        _swapV4To(key, ClPriceMath.sqrtRatioAtTick(start + int24(bound(spotShift, -3000, 3000))));
        vm.warp(block.timestamp + 1);
        _setPrices((ETH * bound(priceBps, 9900, 10_100)) / 10_000, USD);
        int24 tickRef = ClPriceMath.tickAtSqrtRatio(ClPriceMath.oracleSqrtPrice(price0, price1, 18, 6));
        int24 twap = _referenceMeanTick();
        (, int24 spot) = _slot0V4(key);
        uint256 a = _distance(spot, tickRef);
        uint256 b = _distance(twap, tickRef);
        uint256 expected = a > b ? a : b;
        ClPriceStateView memory r = oracle.getClPriceState();
        assertEq(r.tickRef, tickRef, "reference tick from the uncapped quotes");
        assertEq(r.meanTick, twap, "reference TWAP in the v4 token order");
        assertEq(r.tickDeviation, expected, "larger of the spot and TWAP distances");
        bool flagged = _state().reasons & LPOracleCodes.CONSISTENCY_DEVIATION != 0;
        assertEq(flagged, expected > TOLERANCE, "flagged exactly above the tolerance");
    }

    // ─── Helpers ───

    /// @dev Initializes a proxy with `market`; any revert other than `MarketMismatch(MARKET)` fails the test.
    function _initializes(
        bytes memory market
    ) internal returns (bool) {
        InitParams memory p = _params();
        p.market = market;
        try new ERC1967Proxy(address(implementation), abi.encodeCall(ILPOracle.initialize, (p))) {
            return true;
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(ILPOracleErrors.MarketMismatch.selector, MARKET), "revert data");
            return false;
        }
    }

    /// @dev Word `i` of the market encoding: 0 PoolManager, 1-5 the PoolKey (currency0, currency1, fee, tickSpacing,
    /// hooks), 6 tickLower, 7 tickUpper, 8 unitExp, 9 reference pool.
    function _inRange(
        uint256 i,
        uint256 value
    ) internal pure returns (bool) {
        if (i == 5) return value == 0;
        if (i == 3) return value <= type(uint24).max;
        if (i == 8) return value <= 18;
        if (i == 4 || i == 6 || i == 7) {
            int256 v = int256(value);
            if (v < type(int24).min || v > type(int24).max) return false;
            return i != 4 || (v >= 1 && v <= type(int16).max);
        }
        return value <= type(uint160).max;
    }

    /// @dev The reference pool's mean tick over the window, in the v4 pool's token order (native ETH as WETH first).
    function _referenceMeanTick() internal view returns (int24 tick) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = WINDOW;
        (int56[] memory cum,) = IUniswapV3Pool(address(ref)).observe(ago);
        tick = ClPriceMath.meanTick(cum[1] - cum[0], WINDOW);
        if (IUniswapV3Pool(address(ref)).token0() != address(weth)) tick = -tick;
    }

    function _distance(
        int24 x,
        int24 y
    ) internal pure returns (uint256) {
        return x > y ? uint256(int256(x) - int256(y)) : uint256(int256(y) - int256(x));
    }
}
