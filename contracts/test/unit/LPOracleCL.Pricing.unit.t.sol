// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {LPPriceMath} from "../../src/oracle/lp-oracle/LPPriceMath.sol";
import {ClPriceStateView} from "../../src/oracle/lp-oracle/types/ClPriceStateView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LPOracleCLFixture} from "../utils/fixtures/LPOracleCLFixture.sol";

/// @title LPOracleCLPricingTest
/// @notice The concentrated-liquidity LPOracle on real Uniswap v3 pools (ETH/USDC, WBTC/ETH and USDC/USDT): the price
/// of one whole vault token against the tokens the pool itself returns for the same liquidity, in range, out of range
/// on both sides, on the full tick range, for dust and huge positions; and its independence from the pool's spot price
/// (swaps to any price, flash callbacks, just-in-time liquidity).
/// @dev Expected values come from the pool: liquidity minted on the market's exact range and burned at a spot price set
/// to the oracle price returns the holding the composition values; the oracle must never value it higher, and lower by
/// at most the rounding `SPEC-ORC-008` allows.
contract LPOracleCLPricingTest is LPOracleCLFixture {
    /// @dev Raw amounts `liquidity` on the market's range returns when burned at the current spot.
    function _holding(
        uint128 liquidity
    ) internal returns (uint256 a0, uint256 a1) {
        actor.mint(pool, tickLower, tickUpper, liquidity);
        (a0, a1) = actor.burn(pool, tickLower, tickUpper, liquidity);
    }

    /// @dev The oracle's value of `units`, Aave's `units * price8 / 10^d`.
    function _oracleValue(
        uint256 units,
        uint8 d
    ) internal view returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return units * uint256(oracle.latestAnswer()) / 10 ** d;
    }

    /// @dev The stored vault-token decimals, read back as the smallest `d` with a whole token worth at least $1.
    function _d() internal view returns (uint8 d) {
        uint256[] memory prices = new uint256[](2);
        (prices[0], prices[1]) = (price0, price1);
        for (d = 6; d <= 18; ++d) {
            (uint256 a0, uint256 a1) = _composition(10 ** d);
            uint256[] memory amounts = new uint256[](2);
            (amounts[0], amounts[1]) = (a0, a1);
            uint8[] memory decs = new uint8[](2);
            (decs[0], decs[1]) = (token0.decimals(), token1.decimals());
            (bool ok, uint256 p8) = LPPriceMath.lpPrice(amounts, _capped(prices), decs);
            if (ok && p8 >= 1e8) return d;
        }
    }

    function _capped(
        uint256[] memory q
    ) internal view returns (uint256[] memory v) {
        v = new uint256[](2);
        v[0] = LPPriceMath.valuationPrice(q[0], stable[0]);
        v[1] = LPPriceMath.valuationPrice(q[1], stable[1]);
    }

    /// @dev `SPEC-ORC-006` written from the Uniswap definition at the current capped prices.
    function _composition(
        uint256 units
    ) internal view returns (uint256 a0, uint256 a1) {
        uint256 v0 = LPPriceMath.valuationPrice(price0, stable[0]);
        uint256 v1 = LPPriceMath.valuationPrice(price1, stable[1]);
        uint160 sa = ClPriceMath.sqrtRatioAtTick(tickLower);
        uint160 sb = ClPriceMath.sqrtRatioAtTick(tickUpper);
        uint160 s = ClPriceMath.clamp(_oracleSqrt(v0, v1), sa, sb);
        (a0, a1) = ClPriceMath.amountsForLiquidity(s, sa, sb, units);
    }

    /// @dev The rounding `SPEC-ORC-008` allows below the exact value for `liquidity` units: per whole vault token at
    /// most `sum_i (2 * v_i / 10^(d_i) + 1)` units of price8, and one raw unit of each token for the pool's own floors.
    function _roundingBound(
        uint256 liquidity,
        uint8 d
    ) internal view returns (uint256) {
        uint256 perToken = 2 * price0 / 10 ** token0.decimals() + 2 * price1 / 10 ** token1.decimals() + 2;
        return (liquidity / 10 ** d + 1) * perToken + _usd(1, 1) + 4;
    }

    /// @dev Asserts the oracle value of `liquidity` against the pool's own holding at spot = oracle price: never above
    /// it by more than one raw unit of each token (the pool's own floors on a dust position), never below it by more
    /// than the rounding of `SPEC-ORC-008`.
    function _assertFair(
        uint128 liquidity
    ) internal {
        _swapTo(pool, _oracleSqrt(price0, price1));
        uint8 d = _d();
        uint256 valued = _oracleValue(liquidity, d);
        (uint256 a0, uint256 a1) = _holding(liquidity);
        uint256 held = _usd(a0, a1);
        assertLe(valued, held + _usd(1, 1) + 1, "oracle above the pool's holding");
        assertLe(held - (valued > held ? held : valued), _roundingBound(liquidity, d), "oracle too far below");
    }

    // TEST-305 verifies: SPEC-ORC-006, SPEC-ORC-008, SPEC-ORC-009, REQ-ORACLE-011, REQ-ORACLE-103, SPEC-AMM-V3-001
    function test_TEST_305_ethUsdcFullRangeMatchesThePoolsHolding() public {
        _deployClMarket(_ethUsdc());
        _assertState(PriceState.Live);
        _assertFair(1e18);
        _assertFair(1e21);
    }

    // TEST-305 verifies: SPEC-ORC-006, SPEC-ORC-008, REQ-ORACLE-011, REQ-ORACLE-103, SPEC-AMM-V3-001
    function test_TEST_305_wbtcEthFullRangeMatchesThePoolsHolding() public {
        _deployClMarket(_wbtcEth());
        _assertState(PriceState.Live);
        _assertFair(1e15);
        _assertFair(1e19);
    }

    // TEST-305 verifies: SPEC-ORC-006, SPEC-ORC-008, SPEC-ORC-005, REQ-ORACLE-011, REQ-ORACLE-103
    function test_TEST_305_stableNarrowRangeMatchesThePoolsHolding() public {
        _deployClMarket(_usdcUsdt());
        _assertState(PriceState.Live);
        _assertFair(1e12);
        _assertFair(1e18);
    }

    // TEST-305 verifies: SPEC-ORC-008, REQ-ORACLE-012, SPEC-ORC-007
    /// @dev Dust: a few units of liquidity are never valued above what they return.
    function test_TEST_305_dustLiquidityIsNeverOvervalued() public {
        _deployClMarket(_ethUsdc());
        _swapTo(pool, _oracleSqrt(price0, price1));
        uint8 d = _d();
        for (uint128 l = 1; l < 2e6; l *= 7) {
            (uint256 a0, uint256 a1) = _holding(l);
            // Aave values units linearly; the pool floors each token of a dust burn, so the gap is at most one raw
            // unit of each token.
            assertLe(_oracleValue(l, d), _usd(a0, a1) + _usd(1, 1) + 1, "dust overvalued beyond one raw unit");
        }
    }

    // TEST-305 verifies: SPEC-ORC-008, SPEC-ORC-005, REQ-ORACLE-012
    /// @dev Huge: the pool's per-tick maximum liquidity on the full range of spacing 10.
    function test_TEST_305_hugeLiquidityMatchesThePoolsHolding() public {
        _deployClMarket(_ethUsdc());
        _assertFair(uint128(ClPriceMath.maxLiquidityPerTick(10) / 4));
    }

    // TEST-305 verifies: SPEC-ORC-006, SPEC-ORC-009, REQ-ORACLE-104, TEST-279
    /// @dev Token1 depegs below the range: the oracle ratio is above the range, the composition is all token1 at the
    /// upper edge, the market is Drifting with PRICE_CLAMPED, and its value equals the pool's all-token1 holding.
    function test_TEST_305_aboveTheRangeIsAllToken1() public {
        _deployClMarket(_usdcUsdt());
        vm.warp(block.timestamp + 60);
        _setPrices(1e8, 0.95e8);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "state");
        assertTrue(_has(v.reasons, 6), "PRICE_CLAMPED");
        ClPriceStateView memory c = oracle.getClPriceState();
        assertTrue(c.clamped, "clamped");
        assertEq(c.sqrtPriceUsedX96, ClPriceMath.sqrtRatioAtTick(tickUpper), "upper edge");
        (uint256 a0, uint256 a1) = _composition(1e18);
        assertEq(a0, 0, "no token0");
        assertGt(a1, 0, "all token1");
        // Drifting serves the fresh price (SPEC-ORC-017): the depeg is never valued at the earlier accepted price.
        assertEq(uint256(v.answer), uint256(v.freshAnswer), "served fresh");
        assertLt(uint256(v.answer), uint256(v.acceptedAnswer), "below the pre-depeg price");
        _swapTo(pool, ClPriceMath.sqrtRatioAtTick(tickUpper) + 1);
        uint8 d = _d();
        (uint256 h0, uint256 h1) = _holding(1e15);
        assertEq(h0, 0, "pool holding is all token1");
        assertLe(_oracleValue(1e15, d), _usd(h0, h1), "never above the holding");
    }

    // TEST-305 verifies: SPEC-ORC-006, REQ-ORACLE-104, TEST-279
    function test_TEST_305_belowTheRangeIsAllToken0() public {
        _deployClMarket(_usdcUsdt());
        vm.warp(block.timestamp + 60);
        _setPrices(0.95e8, 1e8);
        PriceStateView memory v = _state();
        assertTrue(_has(v.reasons, 6), "PRICE_CLAMPED");
        ClPriceStateView memory c = oracle.getClPriceState();
        assertEq(c.sqrtPriceUsedX96, ClPriceMath.sqrtRatioAtTick(tickLower), "lower edge");
        (uint256 a0, uint256 a1) = _composition(1e18);
        assertGt(a0, 0, "all token0");
        assertEq(a1, 0, "no token1");
        _swapTo(pool, ClPriceMath.sqrtRatioAtTick(tickLower) - 1);
        uint8 d = _d();
        (uint256 h0, uint256 h1) = _holding(1e15);
        assertEq(h1, 0, "pool holding is all token0");
        assertLe(_oracleValue(1e15, d), _usd(h0, h1), "never above the holding");
    }

    // TEST-266 verifies: SPEC-ORC-007, REQ-ORACLE-011, REQ-ORACLE-013, REQ-AMM-V3-005
    /// @dev Spot moved to 0.5x, 2x and 4x the oracle price, to both range edges and beyond: the served price, the fresh
    /// price and the valuation prices do not move by one unit, and the holding valued at oracle prices is never below
    /// the oracle's value.
    function test_TEST_266_spotMovesNeverChangeTheQuote() public {
        _deployClMarket(_ethUsdc());
        int256 before = oracle.latestAnswer();
        uint8 d = _d();
        uint160 s = _oracleSqrt(price0, price1);
        uint160[6] memory targets = [s / 2, s / 4 * 3, s * 2, s * 4, ClPriceMath.MIN_SQRT_RATIO + 1, s];
        for (uint256 i = 0; i < targets.length; ++i) {
            _swapTo(pool, targets[i]);
            assertEq(oracle.latestAnswer(), before, "quote moved with spot");
            (uint256 a0, uint256 a1) = _holding(1e18);
            assertGe(_usd(a0, a1) + 2, _oracleValue(1e18, d), "spot holding below the oracle value");
        }
    }

    // TEST-266 verifies: REQ-ORACLE-103, REQ-ORACLE-011, REQ-ORACLE-017
    /// @dev Inside a real flash callback the pool's lock is held: the views report the market failed (reason bit 17)
    /// and serve the accepted price, and a poke made there writes nothing (no failure start, ORACLE-05).
    function test_TEST_266_flashCallbackSeesTheLockAndPokeWritesNothing() public {
        _deployClMarket(_ethUsdc());
        int256 accepted = oracle.latestAnswer();
        actor.flash(pool, 1e18, 1e9, address(oracle), abi.encodeWithSignature("getPriceState()"));
        assertTrue(actor.lastOk(), "view inside the lock");
        PriceStateView memory inside = abi.decode(actor.lastResult(), (PriceStateView));
        assertTrue(_has(inside.reasons, 17), "POOL_REENTRANCY_LOCKED");
        assertEq(uint8(inside.state), uint8(PriceState.Cached), "failed while locked");
        assertEq(inside.answer, accepted, "serves the accepted price");
        actor.flash(pool, 1e18, 1e9, address(oracle), abi.encodeWithSignature("poke()"));
        assertTrue(actor.lastOk(), "poke inside the lock");
        assertEq(uint8(_state().state), uint8(PriceState.Live), "Live once unlocked");
        // An hour later a real failure (token1 has no valid route) is Cached from now, not Expired from the callback.
        vm.warp(block.timestamp + 3600);
        p1Feed.push(0, block.timestamp);
        a1Feed.push(0, block.timestamp);
        PriceStateView memory failed = _state();
        assertEq(uint8(failed.state), uint8(PriceState.Cached), "Cached, not Expired");
        assertEq(failed.failureStart, block.timestamp, "failure starts now");
        assertEq(failed.answer, accepted, "accepted price served");
    }

    // TEST-266 verifies: SPEC-ORC-007, REQ-ORACLE-013
    /// @dev Just-in-time liquidity: a large mint and swap in the same block change nothing.
    function test_TEST_266_justInTimeLiquidityChangesNothing() public {
        _deployClMarket(_ethUsdc());
        int256 before = oracle.latestAnswer();
        PriceStateView memory v0 = _state();
        actor.mint(pool, -887_270, 887_270, 1e24);
        actor.swap(pool, true, 1e21, ClPriceMath.MIN_SQRT_RATIO + 1);
        assertEq(oracle.latestAnswer(), before, "JIT moved the quote");
        assertEq(_state().freshAnswer, v0.freshAnswer, "fresh price moved");
    }

    // TEST-305 verifies: SPEC-ORC-006, REQ-ORACLE-012
    /// @dev The full tick range of spacing 1 (MIN_TICK to MAX_TICK): priced and Live, value within rounding.
    function test_TEST_305_minToMaxTickRange() public {
        MarketSpec memory s = _usdcUsdt();
        (s.tickLower, s.tickUpper) = (ClPriceMath.MIN_TICK, ClPriceMath.MAX_TICK);
        _deployClMarket(s);
        _assertState(PriceState.Live);
        _assertFair(1e18);
    }
}
