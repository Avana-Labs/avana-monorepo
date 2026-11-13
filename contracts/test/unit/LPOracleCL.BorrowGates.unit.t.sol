// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {ILPOracleErrors} from "../../src/oracle/lp-oracle/ILPOracleErrors.sol";
import {LPOracleCL} from "../../src/oracle/lp-oracle/LPOracleCL.sol";
import {InitParams} from "../../src/oracle/lp-oracle/types/InitParams.sol";
import {OracleConfig} from "../../src/types/OracleConfig.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LPOracleCLDeployer, LPOracleCLFixture} from "../utils/fixtures/LPOracleCLFixture.sol";
import {OracleFeedMock, ReadMode} from "../utils/mocks/LPOracleMocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice A caller that pokes the LPOracle and then reads its price state in the same call, as the RiskModule's
/// `preBorrowCheck` and Collateralization's pledge do; it never catches the poke's revert.
contract PokeThenRead {
    function pokeThenRead(
        ILPOracle oracle,
        uint256 pokeGas
    ) external returns (uint64 disagreeSince, bool borrowAllowed) {
        oracle.poke{gas: pokeGas}();
        PriceStateView memory v = oracle.getPriceState();
        (disagreeSince, borrowAllowed) = (v.disagreeSince, v.borrowAllowed);
    }
}

/// @title LPOracleCLBorrowGatesTest
/// @notice The borrow-side gates of the real concentrated-liquidity LPOracle on a real Uniswap v3 USDC/USDT pool:
/// each feed's age limit (heartbeat plus margin), the independent second source that a borrow needs and liquidation
/// never needs, the L2 sequencer read and its exact-length rule, and the poke that stores what a later view reads.
contract LPOracleCLBorrowGatesTest is LPOracleCLFixture {
    uint256 internal constant ONE = 1e8;
    uint256 internal constant T1 = T0 + 60;
    uint256 internal constant SEQUENCER_DOWN_BIT = 14;
    uint256 internal constant SECOND_SOURCE_BIT = 16;

    OracleFeedMock internal seqFeed;

    function _stable() internal {
        _deployClMarket(_usdcUsdt());
        vm.warp(T1);
        vm.roll(block.number + 1);
        _setPrices(ONE, ONE);
    }

    /// @dev The stable market on an L2 profile: the same pool and feeds, a sequencer-uptime feed that restarted two
    /// hours before `T0` with a 3,600 s grace period, and an implementation built with `hasSequencer`.
    function _stableOnL2() internal {
        _deployClMarket(_usdcUsdt());
        seqFeed = new OracleFeedMock(0, 0, 2);
        seqFeed.setRound(1, 0, T0 - 7200, T0 - 7200);
        OracleConfig memory c = _config();
        c.sequencer.feed = address(seqFeed);
        c.sequencer.gracePeriod = 3600;
        store.setConfig(c);
        implementation = LPOracleCLDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, true, 7);
        InitParams memory p = _params();
        p.config = c;
        oracle =
            LPOracleCL(address(new ERC1967Proxy(address(implementation), abi.encodeCall(ILPOracle.initialize, (p)))));
        vm.warp(T1);
        vm.roll(block.number + 1);
        _setPrices(ONE, ONE);
    }

    function _next(
        uint256 at
    ) internal {
        vm.warp(at);
        vm.roll(block.number + 1);
    }

    // ─── TEST-250: feed cadence ───

    // TEST-250 verifies: SPEC-ORC-019, SPEC-ORC-015, REQ-ORACLE-043, REQ-ORACLE-100, Q-182, Q-274, Q-322
    // Sources: 5.1 TEST-250 (a stablecoin primary with an 86,400 s heartbeat; a borrow at age 88,200 s passes and at
    // 88,201 s is refused)
    /// @notice Every feed has the 86,400 s heartbeat and the 1,800 s margin, so its age limit is 88,200 s. With every
    /// round published at `T1`, a borrow (which pokes first) at `T1 + 88,200` passes and at `T1 + 88,201` is refused.
    function test_TEST_250_borrowAgeAtHeartbeatPlusMargin() public {
        _stable();
        _next(T1 + MAX_AGE);
        oracle.poke();
        PriceStateView memory v = _state();
        assertEq(v.borrowPriceMaxAge, MAX_AGE, "heartbeat plus margin");
        assertEq(v.servedAge, MAX_AGE, "served at age 88,200");
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertTrue(v.borrowAllowed, "age 88,200 passes");
        vm.warp(T1 + MAX_AGE + 1);
        assertFalse(_state().borrowAllowed, "age 88,201 is refused");
    }

    // TEST-250 verifies: SPEC-ORC-013, SPEC-ORC-015, REQ-ORACLE-068, Q-274
    /// @notice A stale primary whose alternate is older than its own limit leaves the token with no valid route: the
    /// market is Cached (serving the accepted price) and its seizure is blocked, while borrowing is refused too.
    function test_TEST_250_stalePrimaryAndOldAlternateMakeTheTokenCached() public {
        _stable();
        (uint256 accepted,) = oracle.lastAcceptedPrice();
        // Token1's primary stops publishing; its alternate's last round is from T1 too. Token0 keeps publishing.
        uint256 at = T1 + MAX_AGE + 1;
        _next(at);
        p0Feed.push(int256(ONE), at);
        a0Feed.push(int256(ONE), at);
        s0Feed.push(int256(ONE), at);
        a1Feed.push(int256(ONE), T1);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Cached), "no valid route for token1: Cached");
        assertEq(uint256(v.answer), accepted, "Cached serves the accepted price");
        assertTrue(v.liquidationPaused, "the market's seizure is blocked");
        assertFalse(v.borrowAllowed);
        assertEq(v.tokens[1].routeUsed, 0, "token1 quoted by no route");
    }

    // ─── TEST-276: per-feed freshness and the second source ───

    // TEST-276 verifies: REQ-ORACLE-100, SPEC-ORC-020, SPEC-ORC-019, REQ-ORACLE-054, ATTACK-044, ATTACK-056, Q-322, Q-323
    // Sources: 5.1 TEST-276
    /// @notice A borrow needs the second source to agree with the primary within `S` = 100 bps: 98.9 cents against
    /// $1.00 (111 bps) leaves token0 unconfirmed (token bit 4, market bit 16) and refuses the borrow; 99.01 cents
    /// (99 bps) passes. The state, served price and liquidation gate never move.
    function test_TEST_276_secondSourceGatesBorrowOnly() public {
        _stable();
        oracle.poke();
        PriceStateView memory base = _state();
        assertTrue(base.borrowAllowed, "Live, both confirmed");
        s0Feed.push(98_900_000, T1);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Live), "the second source never changes the state");
        assertEq(v.answer, base.answer, "nor the served price");
        assertFalse(v.borrowAllowed);
        assertTrue(_has(v.reasons, SECOND_SOURCE_BIT), "SECOND_SOURCE_DISAGREE");
        assertTrue(v.tokens[0].reasons & (1 << 4) != 0, "token0 outside the tolerance");
        assertEq(v.tokens[1].reasons & (3 << 4), 0, "token1 untouched");
        assertFalse(v.liquidationPaused, "never gates liquidation");
        s0Feed.push(99_010_000, T1);
        v = _state();
        assertTrue(v.borrowAllowed, "within 100 bps");
        assertEq(v.tokens[0].secondSourceDeviationBps, 99);
    }

    // TEST-276 verifies: REQ-ORACLE-100, SPEC-ORC-020, Q-323
    /// @notice A failed second source (revert, short return, oversized return, burnt gas, other decimals, stale)
    /// leaves only its own token unconfirmed with bit 5, and the state, served price, served timestamp and valuation
    /// prices equal those with a valid source; liquidation stays open.
    function test_TEST_276_failedSecondSourceOnlyUnconfirmsItsToken() public {
        _stable();
        oracle.poke();
        PriceStateView memory base = _state();
        ReadMode[4] memory modes = [ReadMode.Revert, ReadMode.Short, ReadMode.Huge, ReadMode.BurnGas];
        for (uint256 i = 0; i < modes.length + 2; ++i) {
            if (i < modes.length) {
                s1Feed.setMode(s1Feed.latestRoundData.selector, modes[i]);
            } else if (i == modes.length) {
                s1Feed.setMode(s1Feed.latestRoundData.selector, ReadMode.Normal);
                s1Feed.setDecimals(18);
            } else {
                s1Feed.setDecimals(8);
                s1Feed.push(int256(ONE), T1 - MAX_AGE - 1);
            }
            PriceStateView memory v = _state();
            assertEq(uint8(v.state), uint8(base.state), "state");
            assertEq(v.answer, base.answer, "served price");
            assertEq(v.servedUpdatedAt, base.servedUpdatedAt, "served timestamp");
            assertEq(v.tokens[0].valuationPrice, base.tokens[0].valuationPrice, "valuation price 0");
            assertEq(v.tokens[1].valuationPrice, base.tokens[1].valuationPrice, "valuation price 1");
            assertEq(oracle.latestAnswer(), v.answer, "latestAnswer is the served price");
            assertFalse(v.borrowAllowed, "borrowing refused");
            assertTrue(v.tokens[1].reasons & (1 << 5) != 0, "token1 SECOND_SOURCE_UNAVAILABLE");
            assertEq(v.tokens[0].reasons & (3 << 4), 0, "token0 still confirmed");
            assertFalse(v.liquidationPaused, "liquidation needs no second source");
        }
    }

    // TEST-276 verifies: REQ-ORACLE-099, SPEC-ORC-021, ATTACK-171, Q-324
    /// @notice On an L2 the sequencer gate: down pauses seizure and blocks borrowing with the state and price
    /// unchanged; after a restart, grace for 3,600 s keeps borrowing closed and seizure open; past grace a borrow needs
    /// rounds newer than the restart; an unreadable feed blocks borrowing and never pauses seizure.
    function test_TEST_276_sequencerGateOnTheRealOracle() public {
        _stableOnL2();
        oracle.poke();
        int256 served = _state().answer;
        assertTrue(_state().borrowAllowed, "up since two hours: borrow allowed");
        seqFeed.setRound(2, 1, T1, T1);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Live), "the state never moves");
        assertEq(v.answer, served, "nor the price");
        assertTrue(v.liquidationPaused, "down: seizure paused");
        assertFalse(v.borrowAllowed);
        assertTrue(_has(v.reasons, SEQUENCER_DOWN_BIT));
        uint256 restart = T1 + 100;
        _next(restart);
        seqFeed.setRound(3, 0, restart, restart);
        v = _state();
        assertTrue(v.inGrace, "grace after the restart");
        assertEq(v.graceEndsAt, restart + 3600);
        assertFalse(v.borrowAllowed);
        assertFalse(v.liquidationPaused, "liquidation runs during grace");
        _next(restart + 3600);
        oracle.poke();
        v = _state();
        assertTrue(v.sequencerReady);
        assertFalse(v.borrowAllowed, "rounds from before the restart");
        _setPrices(ONE, ONE);
        oracle.poke();
        assertTrue(_state().borrowAllowed, "rounds newer than the restart");
        seqFeed.setMode(seqFeed.latestRoundData.selector, ReadMode.Revert);
        v = _state();
        assertFalse(v.borrowAllowed, "unreadable: borrowing blocked");
        assertFalse(v.liquidationPaused, "unreadable: liquidation not paused");
    }

    // ─── TEST-275: the sequencer answer's length ───

    function _round(
        int256 answer
    ) internal pure returns (bytes memory) {
        return abi.encode(uint80(1), answer, T0 - 7200, T0 - 7200, uint80(1));
    }

    function _sized(
        bytes memory round,
        uint256 length
    ) internal pure returns (bytes memory out) {
        out = new bytes(length);
        uint256 n = length < round.length ? length : round.length;
        for (uint256 i = 0; i < n; ++i) {
            out[i] = round[i];
        }
    }

    function _answer(
        bytes memory data
    ) internal {
        vm.clearMockedCalls();
        vm.mockCall(address(seqFeed), abi.encodeCall(OracleFeedMock.latestRoundData, ()), data);
    }

    function _assertUnknown(
        int256 served,
        string memory what
    ) internal view {
        PriceStateView memory v = _state();
        assertFalse(v.borrowAllowed, what);
        assertFalse(v.sequencerReady, what);
        assertTrue(_has(v.reasons, SEQUENCER_DOWN_BIT), what);
        assertFalse(v.liquidationPaused, what);
        assertEq(uint8(v.state), uint8(PriceState.Live), what);
        assertEq(v.answer, served, what);
    }

    /// @notice External entry run in its own frame, so the caller's memory does not price the evaluation.
    function measureEvaluation() external view returns (uint256 used, bool unknown) {
        uint256 before = gasleft();
        PriceStateView memory v = oracle.getPriceState();
        used = before - gasleft();
        unknown = !v.borrowAllowed && !v.liquidationPaused && _has(v.reasons, SEQUENCER_DOWN_BIT);
    }

    // TEST-275 verifies: SPEC-ORC-021, REQ-ORACLE-099
    // Sources: 5.1 TEST-275 (the LPOracle read classifies an answer that is not exactly 160 bytes as sequencerUnknown)
    /// @notice Exactly 160 bytes behaves as before (up admits a borrow, down pauses seizure); 159, 161 and 192 bytes and
    /// 1 MB are unknown: borrowing blocked with `SEQUENCER_DOWN`, liquidation not paused, state and price unchanged,
    /// whether the first 160 bytes report up or down.
    function test_TEST_275_sequencerAnswerMustBeExactly160Bytes() public {
        _stableOnL2();
        oracle.poke();
        bytes memory up = _round(0);
        bytes memory down = _round(1);
        _answer(up);
        PriceStateView memory v = _state();
        assertTrue(v.borrowAllowed, "160 bytes, up");
        int256 served = v.answer;
        _answer(down);
        v = _state();
        assertFalse(v.borrowAllowed, "160 bytes, down");
        assertTrue(v.liquidationPaused, "160 bytes, down: seizure paused");
        _answer(_sized(up, 159));
        _assertUnknown(served, "159 bytes");
        _answer(_sized(up, 161));
        _assertUnknown(served, "161 bytes");
        _answer(abi.encodePacked(up, uint256(0)));
        _assertUnknown(served, "192 bytes");
        _answer(_sized(up, 1 << 20));
        _assertUnknown(served, "1 MB");
        _answer(abi.encodePacked(down, uint256(0)));
        _assertUnknown(served, "192 bytes reporting down");
        _answer(up);
        assertTrue(_state().borrowAllowed, "back to 160 bytes");
    }

    // TEST-275 verifies: SPEC-ORC-021, SPEC-ORC-023
    /// @notice A 1 MB sequencer answer costs the evaluation no more gas than a 192-byte one.
    function test_TEST_275_oversizedSequencerAnswerCostsNoMore() public {
        _stableOnL2();
        oracle.poke();
        bytes memory up = _round(0);
        _answer(abi.encodePacked(up, uint256(0)));
        this.measureEvaluation();
        (uint256 longerGas, bool longerUnknown) = this.measureEvaluation();
        _answer(_sized(up, 1 << 20));
        (uint256 hugeGas, bool hugeUnknown) = this.measureEvaluation();
        assertTrue(longerUnknown && hugeUnknown, "a longer answer is unknown");
        assertLe(hugeGas, longerGas, "1 MB costs no more than 192 bytes");
    }

    // ─── TEST-163: the poke runs before the reads ───

    // TEST-163 verifies: REQ-ORACLE-028, REQ-ORACLE-036, REQ-ORACLE-074
    // Sources: 5.1 TEST-163 (LPOracle part: a disagreement first seen in the caller's poke is stored before its view
    // checks read the state; a poke that reverts for low gas makes the whole call revert rather than skip the store)
    /// @notice A caller that pokes and then reads in one call sees the disagreement start stored by its own poke, at
    /// the current time, and a refused borrow. With less gas than `pokeMinGas` forwarded to the poke, the whole call
    /// reverts with `InsufficientGas` and nothing is stored, so no check can run on an unstored observation.
    function test_TEST_163_pokeStoresTheDisagreementBeforeTheCallerReads() public {
        _stable();
        PokeThenRead caller = new PokeThenRead();
        a1Feed.push(97_500_000, T1);
        assertEq(_state().disagreeSince, 0, "no poke has seen it");
        vm.expectPartialRevert(ILPOracleErrors.InsufficientGas.selector);
        caller.pokeThenRead(oracle, POKE_FLOOR - 50_000);
        assertEq(_state().disagreeSince, 0, "a gas-starved poke stores nothing");
        (uint64 since, bool borrowAllowed) = caller.pokeThenRead(oracle, POKE_CEILING);
        assertEq(since, T1, "stored by the caller's own poke before its read");
        assertFalse(borrowAllowed, "the caller's check sees the disagreement");
        assertEq(_state().disagreeSince, T1, "and it stays stored");
        _next(T1 + 600);
        (since,) = caller.pokeThenRead(oracle, POKE_CEILING);
        assertEq(since, T1, "a later poke keeps the first observation");
        assertEq(_state().tokens[1].legFeeds[0], address(a1Feed), "valued at the lower route");
    }
}
