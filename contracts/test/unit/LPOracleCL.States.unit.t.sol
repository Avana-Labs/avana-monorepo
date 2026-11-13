// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {ClPriceStateView} from "../../src/oracle/lp-oracle/types/ClPriceStateView.sol";
import {OracleConfig} from "../../src/types/OracleConfig.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {LPOracleCLFixture} from "../utils/fixtures/LPOracleCLFixture.sol";
import {OracleFeedMock} from "../utils/mocks/LPOracleMocks.sol";

/// @title LPOracleCLStatesTest
/// @notice The price states of the real concentrated-liquidity LPOracle on real Uniswap v3 pools: the four states and
/// their precedence, recomputed on every read; each Drifting cause (route disagreement, USD band, TWAP consistency,
/// clamped price); automatic route failover and the standby slot read on the next evaluation; leg validity; the tick
/// orientation of the consistency check for both token orders; and the TEST-006 driver, which moves the state through
/// the aggregators (`vm.mockCall`, stale rounds) and the pool alone.
contract LPOracleCLStatesTest is LPOracleCLFixture {
    uint256 internal constant ONE = 1e8;
    uint256 internal constant T1 = T0 + 60;

    /// @dev The USDC/USDT market one block after listing, every feed at $1.00.
    function _stable() internal {
        _deployClMarket(_usdcUsdt());
        vm.warp(T1);
        vm.roll(block.number + 1);
        _setPrices(ONE, ONE);
    }

    /// @dev Pushes `price` on token0's primary, alternate and second source at `at`.
    function _token0(
        uint256 price,
        uint256 at
    ) internal {
        p0Feed.push(int256(price), at);
        a0Feed.push(int256(price), at);
        s0Feed.push(int256(price), at);
    }

    /// @dev Holds the pool at `target` for a whole TWAP window, then republishes the oracle prices.
    function _holdPool(
        uint160 target
    ) internal {
        _swapTo(pool, target);
        vm.warp(block.timestamp + WINDOW + 1);
        vm.roll(block.number + 200);
        _setPrices(price0, price1);
    }

    // ─── TEST-006: the price-state driver on the real oracle ───

    // TEST-006 verifies: REQ-ORACLE-016, REQ-ORACLE-018, REQ-ORACLE-071
    /// @notice Live; Drifting from the pool side (the pool held 1 % off the oracle price across `twapWindow`); Live
    /// again once the pool returns; Cached when `vm.mockCall` makes both aggregators of token1 revert, serving the
    /// accepted price; Expired once the failure outlasts `cachedWindow`, serving 1; Live again when the mocks are
    /// cleared. Only the collateral side moves: nothing outside the market's feeds and pool is touched.
    function test_TEST_006_drivesEachStateThroughTheAggregatorsAndThePool() public {
        _stable();
        _assertState(PriceState.Live);
        uint160 peg = _oracleSqrt(ONE, ONE);
        _holdPool(uint160(uint256(peg) * 1005 / 1000));
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "pool held off the oracle price");
        assertTrue(_has(v.reasons, 4), "CONSISTENCY_DEVIATION");
        _holdPool(peg);
        _assertState(PriceState.Live);
        oracle.poke();
        (uint256 accepted,) = oracle.lastAcceptedPrice();
        vm.mockCallRevert(address(p1Feed), abi.encodeCall(OracleFeedMock.latestRoundData, ()), "down");
        vm.mockCallRevert(address(a1Feed), abi.encodeCall(OracleFeedMock.latestRoundData, ()), "down");
        _assertState(PriceState.Cached);
        assertEq(uint256(oracle.latestAnswer()), accepted, "Cached serves the accepted price");
        oracle.poke();
        uint256 failedAt = block.timestamp;
        vm.warp(failedAt + 3600);
        _token0(ONE, block.timestamp);
        _assertState(PriceState.Expired);
        assertEq(oracle.latestAnswer(), 1, "Expired serves 1");
        vm.clearMockedCalls();
        _setPrices(ONE, ONE);
        assertTrue(uint8(_state().state) < uint8(PriceState.Cached), "the aggregators answer again");
    }

    // TEST-006 verifies: REQ-ORACLE-018, REQ-ORACLE-016
    /// @notice Moving one route of token0 2.5 % away makes the market Drifting with the disagreement reason and nothing
    /// else; moving it back is Live on the next read. Token1's routes left to age past `feedMaxAge` while token0 keeps
    /// publishing make the market Cached from the stale rounds' own timestamps.
    function test_TEST_006_oneRouteMovedThenStaleRounds() public {
        _stable();
        a0Feed.push(97_500_000, T1);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "one route moved");
        assertTrue(_has(v.reasons, 2), "ANY_TOKEN_DISAGREE");
        assertFalse(_has(v.reasons, 4) || _has(v.reasons, 3), "the quote is still the primary: no other cause");
        a0Feed.push(int256(ONE), T1);
        _assertState(PriceState.Live);
        uint256 later = T1 + MAX_AGE + 1;
        vm.warp(later);
        _token0(ONE, later);
        s1Feed.push(int256(ONE), later);
        v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Cached), "token1 stale on both routes");
        assertEq(v.failureStart, T1 + MAX_AGE + 1, "the first second both routes were stale");
    }

    // ─── TEST-039: the four states, Drifting causes and precedence ───

    // TEST-039 verifies: REQ-ORACLE-016, REQ-ORACLE-018
    /// @notice Precedence and no hysteresis: a failed token outranks a disagreement (Cached, not Drifting), the
    /// failure outlasting `cachedWindow` is Expired on a view with no poke in between, and the moment both routes
    /// answer again and agree the next read is Live (the outage latch aside, no stored state holds an old state).
    function test_TEST_039_failureOutranksDriftingAndNothingLingers() public {
        _stable();
        a0Feed.push(97_000_000, T1);
        assertEq(uint8(_state().state), uint8(PriceState.Drifting), "disagreement alone: Drifting");
        vm.mockCallRevert(address(p1Feed), abi.encodeCall(OracleFeedMock.latestRoundData, ()), "down");
        vm.mockCallRevert(address(a1Feed), abi.encodeCall(OracleFeedMock.latestRoundData, ()), "down");
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Cached), "a failed token outranks the disagreement");
        assertTrue(_has(v.reasons, 0), "ANY_TOKEN_NO_ROUTE");
        assertEq(v.failureStart, T1, "a view measures the failure from now");
        vm.clearMockedCalls();
        assertEq(uint8(_state().state), uint8(PriceState.Drifting), "recomputed on the next read");
        a0Feed.push(int256(ONE), T1);
        _assertState(PriceState.Live);
        // Expired on a read with no poke: the failure start comes from the stale rounds' own timestamps.
        uint256 staleAt = T1 + MAX_AGE + 1;
        vm.warp(staleAt + 3600);
        _token0(ONE, block.timestamp);
        s1Feed.push(int256(ONE), block.timestamp);
        v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Expired), "Expired at failureStart + cachedWindow, unpoked");
        assertEq(v.failureStart, staleAt);
    }

    // TEST-039 verifies: REQ-ORACLE-016, REQ-ORACLE-018
    /// @notice The second source, the token-decimals verification age and the borrow age are reported beside the
    /// state and never change it: a disagreeing second source sets bit 16 and clears `borrowAllowed` while the market
    /// stays Live at the same served price; a verification older than 7,200 s sets bit 19 the same way.
    function test_TEST_039_borrowGatesNeverChangeTheState() public {
        _stable();
        oracle.poke();
        PriceStateView memory live = _state();
        assertTrue(live.borrowAllowed, "every gate passes");
        s1Feed.push(95_000_000, T1);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Live), "second source: still Live");
        assertTrue(_has(v.reasons, 16), "SECOND_SOURCE_DISAGREE");
        assertFalse(v.borrowAllowed, "borrowing refused");
        assertEq(v.answer, live.answer, "same served price");
        assertEq(v.liquidationPaused, live.liquidationPaused, "same seizure gate");
        s1Feed.push(int256(ONE), T1);
        vm.warp(T1 + 7201);
        _setPrices(ONE, ONE);
        v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Live), "old verification: still Live");
        assertTrue(_has(v.reasons, 19), "DECIMALS_UNVERIFIED");
        assertFalse(v.borrowAllowed, "borrowing refused");
        assertFalse(v.liquidationPaused, "seizure unaffected");
        oracle.poke();
        assertTrue(_state().borrowAllowed, "a poke verifies the decimals again");
    }

    // TEST-043 verifies: REQ-ORACLE-073, REQ-ORACLE-018
    /// @notice The LPOracle's side of a USD-band breach: both tokens at $0.89 on every route, fresh and agreeing, take
    /// the LP's USD level out of the band [0.90, 1.02], so the market is Drifting with `USD_BAND` only; `borrowAllowed`
    /// is false (the RiskModule's `PriceNotLive` for borrow and withdraw-with-debt), seizure is not paused and the
    /// fresh price is served for liquidation. Back at $1.00 the next read is Live and borrowing is allowed again.
    function test_TEST_043_usdBandBreachIsDriftingAndKeepsLiquidation() public {
        _stable();
        _setPrices(89_000_000, 89_000_000);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "Drifting");
        assertTrue(_has(v.reasons, 3), "USD_BAND");
        assertFalse(_has(v.reasons, 2) || _has(v.reasons, 4) || _has(v.reasons, 6), "the band is the only cause");
        assertFalse(v.borrowAllowed, "borrow and withdraw-with-debt blocked");
        assertFalse(v.liquidationPaused, "liquidation continues");
        assertEq(v.answer, v.freshAnswer, "served at the fresh price");
        _setPrices(ONE, ONE);
        v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Live), "back inside the band");
        assertTrue(v.borrowAllowed, "borrowing restored");
    }

    // TEST-039 verifies: REQ-ORACLE-072, REQ-ORACLE-018
    /// @notice Token0 at $0.99 on every route moves the oracle ratio about 100 ticks, below the market's ±10-tick range
    /// (a move up would be valued at the $1.00 stable ceiling and not move the ratio): the module clamps the price to
    /// the range edge, the market is Drifting with `PRICE_CLAMPED`, nothing reverts and the composition is the
    /// one-token holding at the lower edge.
    function test_TEST_039_ratioOutsideTheRangeIsClampedNotAReverts() public {
        _stable();
        _token0(99_000_000, T1);
        price0 = 99_000_000;
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "Drifting");
        assertTrue(_has(v.reasons, 6), "PRICE_CLAMPED");
        assertGe(oracle.latestAnswer(), 1, "no revert, a price is served");
        ClPriceStateView memory r = oracle.getClPriceState();
        assertTrue(r.clamped, "clamped");
        assertLt(r.sqrtPriceOracleX96, ClPriceMath.sqrtRatioAtTick(tickLower), "the oracle ratio is below the range");
        assertEq(r.sqrtPriceUsedX96, ClPriceMath.sqrtRatioAtTick(tickLower), "valued at the lower edge");
        assertEq(uint8(oracle.poke()), uint8(PriceState.Drifting), "poke completes too");
    }

    // TEST-039 verifies: REQ-ORACLE-071, REQ-ORACLE-018
    /// @notice A consistency check that fails (pool TWAP 1 % off) or is unavailable (a zero window) makes the market
    /// Drifting, serving the fresh Chainlink price with borrowing blocked and the accepted price reported for the
    /// borrow-side checks.
    function test_TEST_039_consistencyFailureServesFreshAndBlocksBorrowing() public {
        _stable();
        oracle.poke();
        (uint256 accepted,) = oracle.lastAcceptedPrice();
        _holdPool(uint160(uint256(_oracleSqrt(ONE, ONE)) * 1005 / 1000));
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "Drifting");
        assertTrue(_has(v.reasons, 4), "CONSISTENCY_DEVIATION");
        assertGt(v.consistencyDeviationBps, TOLERANCE, "beyond tau");
        assertEq(v.answer, v.freshAnswer, "served at the fresh price");
        assertFalse(v.borrowAllowed, "borrowing blocked");
        assertFalse(v.liquidationPaused, "seizure open");
        assertEq(uint256(v.acceptedAnswer), accepted, "the accepted price is reported for the borrow-side checks");
        _holdPool(_oracleSqrt(ONE, ONE));
        _assertState(PriceState.Live);
        OracleConfig memory c = _config();
        c.twapWindow = 0;
        store.setConfig(c);
        v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "unavailable check: Drifting");
        assertTrue(_has(v.reasons, 5), "CONSISTENCY_UNAVAILABLE");
        assertFalse(v.borrowAllowed, "borrowing blocked");
        assertEq(v.answer, v.freshAnswer, "served at the fresh price");
    }

    // ─── TEST-040: failover, leg validity, agreement and same-round reads ───

    // TEST-040 verifies: REQ-ORACLE-007, REQ-ORACLE-006, REQ-ORACLE-019
    /// @notice Failover is automatic: a stale primary with a fresh alternate is Live on the alternate, and the primary
    /// serves again on the next read once it is fresh, with no transaction. A fresh but wrong primary is caught by the
    /// agreement check. A guardian's standby switch in the MarketRegistry is read on the next evaluation, and the
    /// LPOracle has no selector that disables or re-enables a route.
    function test_TEST_040_failoverIsAutomaticAndNoSwitchDisablesARoute() public {
        _stable();
        uint256 t = T1 + MAX_AGE + 1;
        vm.warp(t);
        a0Feed.push(int256(ONE), t);
        s0Feed.push(int256(ONE), t);
        p1Feed.push(int256(ONE), t);
        a1Feed.push(int256(ONE), t);
        s1Feed.push(int256(ONE), t);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Live), "stale primary, fresh alternate: Live");
        assertEq(v.tokens[0].routeUsed, 2, "token0 on its alternate");
        assertTrue(_has(v.reasons, 7), "ANY_TOKEN_ON_ALTERNATE");
        p0Feed.push(int256(ONE), t);
        assertEq(_state().tokens[0].routeUsed, 1, "the primary serves again on the next read");
        // A fresh but wrong primary: the agreement check catches it.
        p0Feed.push(96_000_000, t);
        assertTrue(_has(_state().reasons, 2), "wrong primary: ANY_TOKEN_DISAGREE");
        // The guardian switches token0's primary slot to a standby route: read on the next evaluation.
        OracleFeedMock standby = _feed("standby", ONE);
        registry.setRoutes(address(token0), _one(address(standby)), _one(address(a0Feed)), RouteSlot.Primary);
        registry.bumpVersion(address(token0));
        v = _state();
        assertEq(v.tokens[0].legFeeds[0], address(standby), "the standby primary is in force");
        assertEq(uint8(v.tokens[0].replaced), uint8(RouteSlot.Primary), "reported as replaced");
        assertTrue(_has(v.reasons, 13), "ANY_TOKEN_ON_STANDBY");
        assertFalse(_has(v.reasons, 2), "the standby agrees with the alternate");
        bytes[4] memory switches = [
            abi.encodeWithSignature("disableRoute(uint8,uint8)", uint8(0), uint8(0)),
            abi.encodeWithSignature("setRouteEnabled(uint8,uint8,bool)", uint8(0), uint8(0), false),
            abi.encodeWithSignature("disablePrimary(address)", address(token0)),
            abi.encodeWithSignature("useAlternate(address)", address(token0))
        ];
        for (uint256 i = 0; i < switches.length; ++i) {
            vm.prank(tl);
            (bool ok,) = address(oracle).call(switches[i]);
            assertFalse(ok, "no route switch on the LPOracle");
        }
    }

    // TEST-040 verifies: REQ-ORACLE-002, REQ-ORACLE-003, REQ-ORACLE-008
    /// @notice Each failed leg condition sends token0 to its alternate: an answer at `minAnswer` or `maxAnswer`, zero or
    /// negative, `updatedAt` 0 or in the future, other decimals than pinned, an age one second past `feedMaxAge`; an
    /// age exactly at `feedMaxAge` is fresh. The agreement check runs only while both routes report.
    function test_TEST_040_legValidityAndAgreementOnlyWhenBothReport() public {
        _stable();
        uint256 t = T1;
        p0Feed.push(1, t);
        assertEq(_state().tokens[0].routeUsed, 2, "answer == minAnswer");
        p0Feed.push(1e18, t);
        assertEq(_state().tokens[0].routeUsed, 2, "answer == maxAnswer");
        p0Feed.push(0, t);
        assertEq(_state().tokens[0].routeUsed, 2, "answer 0");
        p0Feed.push(-1, t);
        assertEq(_state().tokens[0].routeUsed, 2, "negative answer");
        p0Feed.setRound(20, int256(ONE), t, 0);
        assertEq(_state().tokens[0].routeUsed, 2, "updatedAt == 0");
        p0Feed.setRound(21, int256(ONE), t, t + 1);
        assertEq(_state().tokens[0].routeUsed, 2, "updatedAt in the future");
        p0Feed.push(int256(ONE), t);
        p0Feed.setDecimals(18);
        assertEq(_state().tokens[0].routeUsed, 2, "decimals other than pinned");
        p0Feed.setDecimals(8);
        vm.warp(t + MAX_AGE);
        _setPrices(ONE, ONE);
        p0Feed.setRound(22, int256(ONE), t, t);
        assertEq(_state().tokens[0].routeUsed, 1, "age == feedMaxAge is fresh");
        p0Feed.setRound(23, int256(ONE), t - 1, t - 1);
        PriceStateView memory v = _state();
        assertEq(v.tokens[0].routeUsed, 2, "one second older is stale");
        // With the primary invalid, a disagreeing alternate is not compared with anything.
        a0Feed.push(97_000_000, block.timestamp);
        v = _state();
        assertFalse(_has(v.reasons, 2), "one valid route: no agreement check");
        p0Feed.push(int256(ONE), block.timestamp);
        assertTrue(_has(_state().reasons, 2), "both report and disagree");
    }

    // TEST-040 verifies: REQ-ORACLE-021, REQ-ORACLE-066
    /// @notice Reading and caching the same rounds never refreshes their timestamp: an hour later the served
    /// timestamp and the accepted timestamp are still the rounds' own.
    function test_TEST_040_sameRoundNeverRefreshes() public {
        _stable();
        oracle.poke();
        vm.warp(T1 + 3600);
        vm.roll(block.number + 300);
        oracle.poke();
        PriceStateView memory v = _state();
        assertEq(v.servedUpdatedAt, T1, "the rounds' own timestamp");
        assertEq(v.servedAge, 3600, "aged by the hour");
        (, uint64 at) = oracle.lastAcceptedPrice();
        assertEq(at, T1, "the accepted timestamp is not refreshed");
    }

    // ─── TEST-041: tick orientation ───

    // TEST-041 verifies: REQ-ORACLE-014, SPEC-ORC-010
    /// @notice The consistency check compares in ticks with `tickRef` oriented token1/token0 in raw units from the
    /// pool's `token0()`, `token1()` and their decimals. WETH/USDC markets are listed until both orders occur (WETH as
    /// token0 and as token1, set by the token addresses): each is Live at peg with a deviation of at most one tick,
    /// and the reference has the sign of its orientation (WETH per USDC raw is about 3·10⁻⁹, tick about −195,000;
    /// USDC per WETH raw is about 3.3·10⁸, tick about +195,000).
    function test_TEST_041_bothTokenOrdersAreLiveAtPeg() public {
        bool wethFirst;
        bool usdcFirst;
        for (uint256 k = 0; k < 8 && !(wethFirst && usdcFirst); ++k) {
            _deployClMarket(_ethUsdc());
            vm.roll(block.number + 1);
            ClPriceStateView memory r = oracle.getClPriceState();
            PriceStateView memory v = _state();
            assertEq(uint8(v.state), uint8(PriceState.Live), "Live at peg");
            assertLe(r.tickDeviation, 1, "the pool TWAP is the reference tick");
            assertEq(r.tickRef, ClPriceMath.tickAtSqrtRatio(_oracleSqrt(price0, price1)), "tickRef");
            if (token0.decimals() == 18) {
                wethFirst = true;
                assertLt(r.tickRef, -190_000, "WETH as token0: raw USDC per WETH is tiny");
            } else {
                usdcFirst = true;
                assertGt(r.tickRef, 190_000, "USDC as token0: raw WETH per USDC is large");
            }
        }
        assertTrue(wethFirst && usdcFirst, "both orders listed");
    }
}
