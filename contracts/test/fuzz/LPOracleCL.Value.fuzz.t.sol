// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {LPPriceMath} from "../../src/oracle/lp-oracle/LPPriceMath.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LPOracleCLFixture} from "../utils/fixtures/LPOracleCLFixture.sol";

/// @title LPOracleCLValueFuzzTest
/// @notice The value the real concentrated-liquidity LPOracle serves, fuzzed on real Uniswap v3 pools: never above
/// what the units it values return when removed from the pool at any spot price, rounded down at every step, and
/// free of overflow across the listing bounds of every answer.
/// @dev Markets: USDC/USDT (6/6) on `[-10, 10]`, WETH/USDC (18/6), WBTC/WETH (8/18) and a 12/18-decimal pair on the
/// full range, each listed at its fixture prices.
contract LPOracleCLValueFuzzTest is LPOracleCLFixture {
    uint256 internal constant ONE = 1e8;

    function _spec(
        uint256 which,
        uint128 poolLiquidity
    ) internal pure returns (MarketSpec memory s) {
        which = which % 4;
        if (which == 0) s = _usdcUsdt();
        else if (which == 1) s = _ethUsdc();
        else if (which == 2) s = _wbtcEth();
        else s = MarketSpec("T12", 12, 2e8, false, "T18", 18, 5e7, false, 3000, true, 0, 0, 1e15);
        s.poolLiquidity = poolLiquidity;
    }

    function _v(
        uint256 q,
        uint256 i
    ) internal view returns (uint256) {
        return LPPriceMath.valuationPrice(q, stable[i]);
    }

    /// @dev The stored vault-token decimals: the smallest `d` with a whole token worth at least $1 at the listing
    /// valuation prices.
    function _d() internal view returns (uint8 d) {
        uint256[] memory prices = new uint256[](2);
        (prices[0], prices[1]) = (_v(price0, 0), _v(price1, 1));
        uint8[] memory decs = new uint8[](2);
        (decs[0], decs[1]) = (token0.decimals(), token1.decimals());
        for (d = 6; d <= 18; ++d) {
            (uint256 a0, uint256 a1) = _composition(10 ** d, prices[0], prices[1]);
            uint256[] memory amounts = new uint256[](2);
            (amounts[0], amounts[1]) = (a0, a1);
            (bool ok, uint256 p8) = LPPriceMath.lpPrice(amounts, prices, decs);
            if (ok && p8 >= ONE) return d;
        }
    }

    /// @dev `SPEC-ORC-006` from the Uniswap definition at valuation prices `v0`, `v1`.
    function _composition(
        uint256 units,
        uint256 v0,
        uint256 v1
    ) internal view returns (uint256 a0, uint256 a1) {
        uint160 sa = ClPriceMath.sqrtRatioAtTick(tickLower);
        uint160 sb = ClPriceMath.sqrtRatioAtTick(tickUpper);
        uint160 s = ClPriceMath.clamp(_oracleSqrt(v0, v1), sa, sb);
        (a0, a1) = ClPriceMath.amountsForLiquidity(s, sa, sb, units);
    }

    /// @dev USD value, 8 decimals, of raw amounts at the valuation prices `v0`, `v1`.
    function _value(
        uint256 a0,
        uint256 a1,
        uint256 v0,
        uint256 v1
    ) internal view returns (uint256) {
        return a0 * v0 / 10 ** token0.decimals() + a1 * v1 / 10 ** token1.decimals();
    }

    /// @dev Moves each token's feeds to `factor / 100` of its listing price (factor in [1, 200]: 0.01 to 2.0).
    function _movePrices(
        uint256 f0,
        uint256 f1
    ) internal {
        vm.warp(block.timestamp + 60);
        vm.roll(block.number + 1);
        _setPrices(price0 * bound(f0, 1, 200) / 100, price1 * bound(f1, 1, 200) / 100);
    }

    // TEST-217 verifies: INV-078, REQ-ORACLE-011, REQ-ORACLE-012, SPEC-ORC-007, SPEC-ORC-008, ATTACK-154
    // Sources: 5.1 TEST-217 (LPOracle part: pool liquidity 10^4 to 10^15, Chainlink answers 0.01 to 2.0 times the
    // listing price per leg, spot independent of the feeds, decimals 6, 8, 12 and 18, removal of 0 to 100 % of a
    // position; price8 * units / 10^d never exceeds the value at oracle prices of the amounts the removal returns)
    /// @notice For every market, pool depth, oracle price vector, spot price and removed share of a position minted
    /// on the market's exact range, the value the LPOracle serves for the removed units is at most the oracle-priced
    /// value of the tokens the pool returns for them (to one raw unit of each token, the pool's own floor).
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_TEST_217_removalAtAnySpotCoversTheServedValue(
        uint256 which,
        uint256 poolLiquidity,
        uint256 f0,
        uint256 f1,
        uint256 spotK,
        uint256 liquidity,
        uint256 shareBps
    ) public {
        _deployClMarket(_spec(which, uint128(bound(poolLiquidity, 1e4, 1e15))));
        uint8 d = _d();
        _movePrices(f0, f1);
        PriceStateView memory v = _state();
        vm.assume(v.state != PriceState.Cached && v.state != PriceState.Expired);
        uint256 v0 = v.tokens[0].valuationPrice;
        uint256 v1 = v.tokens[1].valuationPrice;
        // Spot anywhere from 1/16 to 16 times the oracle square-root price, independent of the feeds.
        uint256 target = uint256(_oracleSqrt(price0, price1)) * bound(spotK, 4, 1024) / 64;
        if (target <= ClPriceMath.MIN_SQRT_RATIO) target = ClPriceMath.MIN_SQRT_RATIO + 1;
        if (target >= ClPriceMath.MAX_SQRT_RATIO) target = ClPriceMath.MAX_SQRT_RATIO - 1;
        _swapTo(pool, uint160(target));
        uint128 l = uint128(bound(liquidity, 1e4, 1e18));
        uint128 removed = uint128(uint256(l) * bound(shareBps, 0, 10_000) / 10_000);
        actor.mint(pool, tickLower, tickUpper, l);
        uint256 a0 = 0;
        uint256 a1 = 0;
        if (removed > 0) (a0, a1) = actor.burn(pool, tickLower, tickUpper, removed);
        uint256 served = uint256(oracle.latestAnswer());
        uint256 valued = uint256(removed) * served / 10 ** d;
        uint256 returned = _value(a0, a1, v0, v1);
        assertLe(valued, returned + _value(1, 1, v0, v1) + 1, "served value above the removal's oracle value");
    }

    // TEST-070 verifies: SPEC-ORC-008, REQ-ORACLE-012, MATH-UO-16
    // Sources: 5.1 TEST-070 (LPOracle part: the oracle price rounds down)
    /// @notice The fresh price of one whole vault token is the composition of `10^d` units at the valuation prices,
    /// each amount floored, valued with every division rounded down: never above the exact value of the floored
    /// amounts, and below it by at most the rounding `SPEC-ORC-008` allows (two raw units of each token and one price
    /// unit per token); the served price of a Live market is that fresh price.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_TEST_070_oraclePriceRoundsDown(
        uint256 which,
        uint256 f0,
        uint256 f1
    ) public {
        _deployClMarket(_spec(which, 1e15));
        uint8 d = _d();
        _movePrices(f0, f1);
        PriceStateView memory v = _state();
        vm.assume(v.state != PriceState.Cached && v.state != PriceState.Expired);
        uint256 v0 = v.tokens[0].valuationPrice;
        uint256 v1 = v.tokens[1].valuationPrice;
        (uint256 a0, uint256 a1) = _composition(10 ** d, v0, v1);
        // Exact value of the floored amounts, scaled by 10^18 (token decimals are at most 18).
        uint256 exact18 = a0 * v0 * 10 ** (18 - token0.decimals()) + a1 * v1 * 10 ** (18 - token1.decimals());
        uint256 fresh = uint256(v.freshAnswer);
        assertLe(fresh * 1e18, exact18, "fresh price above the exact value: rounded up");
        // SPEC-ORC-008: below the exact value by at most two raw units of each token plus one price unit per token.
        uint256 allowance18 = 2 * v0 * 10 ** (18 - token0.decimals()) + 2 * v1 * 10 ** (18 - token1.decimals()) + 2e18;
        assertLe(exact18 - fresh * 1e18, allowance18, "below the exact value by more than SPEC-ORC-008 allows");
        if (v.state == PriceState.Live) assertEq(uint256(v.answer), fresh, "Live serves the fresh price");
    }

    // TEST-070 verifies: SPEC-ORC-008, REQ-ORACLE-012, SPEC-ORC-005
    /// @notice WBTC rounding bound. An 8-decimal token is priced per whole vault token, which `SPEC-ORC-005` makes worth
    /// $1 to $10 at listing, so its raw unit ($0.001 at $100,000) is a large share of the price: the floor and the
    /// one-raw-unit deduction of `SPEC-ORC-008` can put the fresh price up to ~2e-3 below the exact value when a whole
    /// token holds only ~500 raw WBTC units (the fixture markets measure 0.3 to 0.6 bps). The test pins
    /// that this shortfall is (1) never negative, (2) at most two raw units of each token's share plus two price units
    /// (`2/a0 + 2/a1 + 2/price8` relative), and (3) at the listing prices of WBTC/WETH and WBTC/USDC below 25 bps,
    /// half the 50 bps deviation threshold of the BTC/USD feed the price already tolerates.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_TEST_070_wbtcRoundingIsBoundedAndDownward(
        bool usdc,
        uint256 f0,
        uint256 f1
    ) public {
        _deployClMarket(
            usdc ? MarketSpec("WBTC", 8, 100_000e8, false, "USDC", 6, 1e8, true, 500, true, 0, 0, 1e15) : _wbtcEth()
        );
        uint8 d = _d();
        for (uint256 step = 0; step < 2; ++step) {
            if (step == 1) _movePrices(bound(f0, 50, 200), bound(f1, 50, 200));
            PriceStateView memory v = _state();
            if (v.state == PriceState.Cached || v.state == PriceState.Expired) continue;
            uint256 v0 = v.tokens[0].valuationPrice;
            uint256 v1 = v.tokens[1].valuationPrice;
            (uint256 a0, uint256 a1) = _composition(10 ** d, v0, v1);
            // Exact value of the composition (before the floor, at most one raw unit above the floored amounts), x 10^18.
            uint256 low18 = a0 * v0 * 10 ** (18 - token0.decimals()) + a1 * v1 * 10 ** (18 - token1.decimals());
            uint256 fresh = uint256(v.freshAnswer);
            assertLe(fresh * 1e18, low18, "fresh price above the value of the floored composition");
            uint256 high18 = low18 + v0 * 10 ** (18 - token0.decimals()) + v1 * 10 ** (18 - token1.decimals());
            // (2): relative shortfall against the unfloored value, in 1e18, below 2/a0 + 2/a1 + 2/price8 (shares of
            // each token at most 1, so 2 raw units of a token are at most 2/a_i of the value).
            uint256 rel18 = (high18 - fresh * 1e18) * 1e18 / high18;
            uint256 allowed18 = 2e18 / a0 + 2e18 / a1 + 2e18 / fresh + 3;
            assertLe(rel18, allowed18, "shortfall above the SPEC-ORC-008 rounding");
            if (step == 0) assertLt(rel18, 25e14, "at listing: below 25 bps");
        }
    }

    // TEST-071 verifies: MATH-UO-05, MATH-UO-29, REQ-ORACLE-012
    // Sources: 5.1 TEST-071 (LPOracle part: amount x price x 10^(18 - decimals) never overflows inside the listing
    // bounds)
    /// @notice With every feed anywhere in its listed bounds `[1, 10^18]`, on every market and the deepest pool
    /// liquidity the fixture lists, no view or poke of the LPOracle reverts; the served price is at least 1 and below
    /// `2^128`, so `units * price8` for any `units < 2^128` fits in 256 bits.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_TEST_071_noOverflowAcrossTheListingBounds(
        uint256 which,
        uint256 q0,
        uint256 q1
    ) public {
        _deployClMarket(_spec(which, 1e18));
        vm.warp(block.timestamp + 60);
        vm.roll(block.number + 1);
        _setPrices(bound(q0, 1, LPPriceMath.MAX_ROUTE_ANSWER), bound(q1, 1, LPPriceMath.MAX_ROUTE_ANSWER));
        PriceStateView memory v = oracle.getPriceState();
        int256 answer = oracle.latestAnswer();
        assertEq(answer, v.answer, "latestAnswer is the reported answer");
        assertGe(answer, 1, "never below 1");
        assertLt(uint256(answer), LPPriceMath.ANSWER_BOUND, "units * price8 fits");
        assertLt(uint256(v.freshAnswer), LPPriceMath.ANSWER_BOUND, "fresh price bounded");
        oracle.getTokenPrices();
        oracle.latestRoundData();
        oracle.poke();
        assertGe(oracle.latestAnswer(), 1, "after the poke");
    }
}
