// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPPriceMath} from "../../src/oracle/lp-oracle/LPPriceMath.sol";
import {RiskModuleMath} from "../../src/policy/risk-module/RiskModuleMath.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LPOracleCLFixture} from "../utils/fixtures/LPOracleCLFixture.sol";
import {OracleStoreMock, ReadMode} from "../utils/mocks/LPOracleMocks.sol";

/// @title LPOracleCLFindingsTest
/// @notice Regression tests of the oracle review on the real concentrated-liquidity LPOracle and real Uniswap v3 pools:
/// the accepted price bounds borrowing only (a rally while Drifting is served fresh, so it never makes an account
/// liquidatable), prices above $10,000 (WBTC, ETH after a rally) stay listable and Live, and a poke from inside the
/// pool's lock writes no failure start that a later failure could inherit.
contract LPOracleCLFindingsTest is LPOracleCLFixture {
    uint256 internal constant ETH = 3000e8;

    function _eth(
        uint256 price
    ) internal {
        // WETH is token0 or token1 depending on the deployed addresses.
        if (token0.decimals() == 18) {
            p0Feed.push(int256(price), block.timestamp);
            a0Feed.push(int256(price), block.timestamp);
            s0Feed.push(int256(price), block.timestamp);
            price0 = price;
        } else {
            p1Feed.push(int256(price), block.timestamp);
            a1Feed.push(int256(price), block.timestamp);
            s1Feed.push(int256(price), block.timestamp);
            price1 = price;
        }
    }

    // TEST-230 verifies: SPEC-ORC-017, REQ-ORACLE-086, REQ-ORACLE-087, REQ-RISK-026, REQ-RISK-059, INV-087
    /// @dev ETH rallies 1 % an hour for 20 hours while USDC/USD publishes no round: the accepted price stays the seed
    /// (REQ-ORACLE-029 stores it only when the oldest leg advances), and the pool's TWAP lags the rally, so the market is
    /// Drifting on CONSISTENCY_DEVIATION. It serves the fresh price, never the 20-hour-old accepted one, so an account
    /// healthy at the fresh price stays healthy; borrowing and pledge booking are held to the accepted price.
    function test_TEST_230_rallyWhileDriftingIsServedFresh() public {
        _deployClMarket(_ethUsdc());
        (uint256 seeded,) = oracle.lastAcceptedPrice();
        for (uint256 h = 1; h <= 20; ++h) {
            vm.warp(T0 + h * 3600);
            vm.roll(block.number + 300);
            _eth(ETH + (ETH * h) / 100);
            oracle.poke();
        }
        PriceStateView memory v = _state();
        (uint256 accepted,) = oracle.lastAcceptedPrice();
        assertEq(accepted, seeded, "accepted price is the seed");
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "Drifting");
        assertTrue(_has(v.reasons, 4), "TWAP lags the rally");
        uint256 fresh = uint256(v.freshAnswer);
        assertGt(fresh * 100, accepted * 109, "fresh is over 9 % above the accepted price");
        assertEq(uint256(v.answer), fresh, "served fresh: the rally never lowers health");
        assertFalse(v.liquidationPaused, "liquidation open");
        // Borrowing: the post-action health factor is held to the accepted price.
        uint256 hf = 1.05e18;
        uint256 bounded = RiskModuleMath.boundedHealthFactor(hf, uint256(v.answer), accepted);
        assertEq(bounded, hf * accepted / fresh, "borrow check at the accepted price");
        assertLt(bounded, hf, "no borrowing power from the rally");
        // Pledge booking at min(fresh, accepted).
        assertEq(RiskModuleMath.bookingPrice(accepted, fresh), accepted, "booking at the accepted price");
    }

    // TEST-230 verifies: SPEC-ORC-017, INV-087
    /// @dev A fall is served at once while Drifting: min(fresh, accepted) = fresh, for liquidation and borrowing alike.
    function test_TEST_230_fallWhileDriftingIsServedFresh() public {
        _deployClMarket(_ethUsdc());
        vm.warp(T0 + 3600);
        _eth(ETH * 80 / 100);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "Drifting on the TWAP");
        assertEq(v.answer, v.freshAnswer, "the fall is served");
        assertLt(uint256(v.answer), uint256(v.acceptedAnswer), "below the accepted price");
        assertEq(RiskModuleMath.bookingPrice(uint256(v.acceptedAnswer), uint256(v.freshAnswer)), uint256(v.freshAnswer));
    }

    // TEST-305 verifies: REQ-ORACLE-049, SPEC-ORC-008, SPEC-ORC-009
    /// @dev WBTC at $150,000 against ETH is Live: route values above the old $10,000 bound are listable
    /// (MAX_ROUTE_ANSWER = 10^18).
    function test_TEST_305_wbtcAboveTenThousandIsLive() public {
        MarketSpec memory s = _wbtcEth();
        s.priceA = 150_000e8;
        _deployClMarket(s);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Live), "Live");
        assertGt(v.freshAnswer, 0, "priced");
        assertGe(LPPriceMath.MAX_ROUTE_ANSWER, 150_000e8, "bound admits WBTC");
    }

    // TEST-305 verifies: REQ-ORACLE-049, REQ-ORACLE-002
    /// @dev ETH rallies past $10,000: the market stays priced (not failed, not Expired), and once the pool's TWAP follows
    /// it is Live again.
    function test_TEST_305_ethAboveTenThousandStaysPriced() public {
        _deployClMarket(_ethUsdc());
        vm.warp(T0 + 600);
        _eth(10_001e8);
        PriceStateView memory v = _state();
        assertTrue(v.state == PriceState.Live || v.state == PriceState.Drifting, "never failed");
        _swapTo(pool, _oracleSqrt(price0, price1));
        vm.warp(block.timestamp + WINDOW + 1);
        vm.roll(block.number + 200);
        _eth(10_001e8);
        _setPrices(price0, price1);
        _assertState(PriceState.Live);
    }

    // TEST-219 verifies: REQ-ORACLE-027, REQ-ORACLE-017, REQ-ORACLE-103
    /// @dev A poke from inside a real flash callback writes nothing; an unrelated failed configuration read an hour
    /// later is Cached from that read, at the accepted price, not Expired from the callback's time.
    function test_TEST_219_lockedPokeLeavesNoFailureStart() public {
        _deployClMarket(_ethUsdc());
        int256 accepted = oracle.latestAnswer();
        vm.warp(T0 + 100);
        actor.flash(pool, 1e18, 0, address(oracle), abi.encodeWithSignature("poke()"));
        assertTrue(actor.lastOk(), "poke inside the lock");
        assertEq(abi.decode(actor.lastResult(), (uint8)), uint8(PriceState.Cached), "reported failed");
        vm.warp(T0 + 100 + 3601);
        _setPrices(price0, price1);
        assertEq(uint8(_state().state), uint8(PriceState.Live), "Live");
        store.setMode(OracleStoreMock.getOracleInputs.selector, ReadMode.Revert);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Cached), "Cached, not Expired");
        assertEq(v.answer, accepted, "accepted price served");
        assertEq(v.failureStart, block.timestamp, "failure starts at the failed read");
    }
}
