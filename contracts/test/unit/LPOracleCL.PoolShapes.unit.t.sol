// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {ILPOracleErrors} from "../../src/oracle/lp-oracle/ILPOracleErrors.sol";
import {LPOracleCL} from "../../src/oracle/lp-oracle/LPOracleCL.sol";
import {LPOracleCodes} from "../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {LPPriceMath} from "../../src/oracle/lp-oracle/LPPriceMath.sol";
import {InitParams} from "../../src/oracle/lp-oracle/types/InitParams.sol";
import {OracleConfig} from "../../src/types/OracleConfig.sol";
import {OracleLeg} from "../../src/types/OracleLeg.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {LPOracleCLDeployer, LPOracleCLFixture} from "../utils/fixtures/LPOracleCLFixture.sol";
import {OracleFeedMock} from "../utils/mocks/LPOracleMocks.sol";
import {ClPoolFaultShim} from "./LPOracleCL.PoolReads.unit.t.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title LPOracleCLPoolShapesTest
/// @notice The real concentrated-liquidity LPOracle on real Uniswap v3 pools against the shapes of the markets it
/// prices: the clamp of a depegged oracle ratio to the market's range, a pool whose reentrancy flag is set, the TWAP
/// buffer sized with the chain's block time, the six-word `slot0` of a Slipstream pool, and a feed whose normalised
/// minimum would round a token's price to 0.
contract LPOracleCLPoolShapesTest is LPOracleCLFixture {
    uint256 internal constant ONE = 1e8;
    uint256 internal constant SHIFT = 16;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant POOL_LOCKED_BIT = 17;

    function _next(
        uint256 at
    ) internal {
        vm.warp(at);
        vm.roll(block.number + 1);
    }

    /// @dev The stored vault-token decimals: the smallest `d` with a whole token worth at least $1 at the listing
    /// prices (both $1 here), from the oracle's own composition rule.
    function _d() internal view returns (uint8 d) {
        uint160 sa = ClPriceMath.sqrtRatioAtTick(tickLower);
        uint160 sb = ClPriceMath.sqrtRatioAtTick(tickUpper);
        uint160 s = ClPriceMath.clamp(_oracleSqrt(ONE, ONE), sa, sb);
        uint8[] memory decs = new uint8[](2);
        (decs[0], decs[1]) = (token0.decimals(), token1.decimals());
        uint256[] memory prices = new uint256[](2);
        (prices[0], prices[1]) = (ONE, ONE);
        for (d = 6; d <= 18; ++d) {
            uint256[] memory amounts = new uint256[](2);
            (amounts[0], amounts[1]) = ClPriceMath.amountsForLiquidity(s, sa, sb, 10 ** d);
            (bool ok, uint256 p8) = LPPriceMath.lpPrice(amounts, prices, decs);
            if (ok && p8 >= ONE) return d;
        }
    }

    // ─── TEST-279: the clamp ───

    // TEST-279 verifies: REQ-ORACLE-104, REQ-ORACLE-072, SPEC-ORC-006, ATTACK-154, INV-078
    // Sources: 5.1 TEST-279 (LPOracle part); FINDING-202 (market [0.99, 1.01], token1 at $0.952: unclamped math gives
    // 2.97 times the holding)
    /// @notice A USDC/USDT market on `[-100, 100]` (about [0.99, 1.01]) with token1 depegged to $0.952: the oracle
    /// ratio is above the range, so the oracle values each unit as the clamped all-token1 holding at the upper edge.
    /// The unclamped formula `L * (s - s_a)` would give about 2.97 times as much token1; the served value of one
    /// vault token never exceeds the clamped holding and never reaches half the unclamped one.
    function test_TEST_279_depeggedRatioBeyondTheEdgeIsClamped() public {
        MarketSpec memory s = _usdcUsdt();
        (s.tickLower, s.tickUpper) = (-100, 100);
        _deployClMarket(s);
        uint8 d = _d();
        _next(block.timestamp + 60);
        _setPrices(ONE, 95_200_000);
        PriceStateView memory v = _state();
        assertTrue(_has(v.reasons, 6), "PRICE_CLAMPED");
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "clamped: Drifting");
        assertEq(uint256(v.answer), uint256(v.freshAnswer), "served at the fresh, clamped value");
        uint256 sa = ClPriceMath.sqrtRatioAtTick(tickLower);
        uint256 sb = ClPriceMath.sqrtRatioAtTick(tickUpper);
        uint256 so = _oracleSqrt(ONE, 95_200_000);
        assertGt(so, sb, "oracle ratio above the range");
        uint256 units = 10 ** d;
        uint256 clamped1 = units * (sb - sa) / Q96;
        uint256 unclamped1 = units * (so - sa) / Q96;
        uint256 clampedUsd = clamped1 * 95_200_000 / 10 ** token1.decimals();
        uint256 unclampedUsd = unclamped1 * 95_200_000 / 10 ** token1.decimals();
        assertGe(unclampedUsd * 100, clampedUsd * 290, "the unclamped formula overvalues about 2.97 times");
        uint256 served = uint256(v.answer);
        assertLe(served, clampedUsd + 1, "never above the clamped all-token1 holding");
        assertApproxEqRel(served, clampedUsd, 1e12, "the clamped holding, to one part per million");
        assertLt(served * 2, unclampedUsd, "the unclamped value never appears");
    }

    // ─── TEST-116: the LPOracle answers while the pool is locked ───

    // TEST-116 verifies: REQ-ORACLE-103, REQ-ORACLE-026, REQ-AMM-V3-003
    // Sources: 5.1 TEST-116 (LPOracle part: while the pool's reentrancy flag is set the LPOracle keeps answering)
    /// @notice Inside a real flash callback the pool's lock is held: `latestAnswer()`, `latestRoundData()`,
    /// `getTokenPrices()` and `getPriceState()` all answer (the market reports the lock with reason bit 17 and serves
    /// its accepted price, never 0 and never a spot-derived value), and a poke there writes nothing.
    function test_TEST_116_oracleKeepsAnsweringWhileThePoolIsLocked() public {
        _deployClMarket(_ethUsdc());
        (uint256 accepted,) = oracle.lastAcceptedPrice();
        actor.flash(pool, 1e18, 1e9, address(oracle), abi.encodeWithSignature("latestAnswer()"));
        assertTrue(actor.lastOk(), "latestAnswer inside the lock");
        assertEq(abi.decode(actor.lastResult(), (uint256)), accepted, "the accepted price");
        actor.flash(pool, 1e18, 1e9, address(oracle), abi.encodeWithSignature("latestRoundData()"));
        assertTrue(actor.lastOk(), "latestRoundData inside the lock");
        actor.flash(pool, 1e18, 1e9, address(oracle), abi.encodeWithSignature("getTokenPrices()"));
        assertTrue(actor.lastOk(), "getTokenPrices inside the lock");
        actor.flash(pool, 1e18, 1e9, address(oracle), abi.encodeWithSignature("getPriceState()"));
        assertTrue(actor.lastOk(), "getPriceState inside the lock");
        PriceStateView memory inside = abi.decode(actor.lastResult(), (PriceStateView));
        assertTrue(_has(inside.reasons, POOL_LOCKED_BIT), "the lock is reported");
        assertEq(uint256(inside.answer), accepted, "serves the accepted price");
        actor.flash(pool, 1e18, 1e9, address(oracle), abi.encodeWithSignature("poke()"));
        assertTrue(actor.lastOk(), "poke inside the lock");
        PriceStateView memory after_ = _state();
        assertEq(after_.failureStart, 0, "the poke inside the lock wrote no failure");
        assertEq(uint8(after_.state), uint8(PriceState.Live), "Live once unlocked");
    }

    // ─── TEST-264: the buffer sized with the chain's block time ───

    // TEST-264 verifies: SPEC-ORC-022, REQ-ORACLE-105, REQ-ORACLE-055
    // Sources: 5.1 TEST-264 (LPOracle part: the consistency check sizes the buffer with the chain's block time, 901
    // observations on Base for 1,800 s)
    /// @notice An LPOracle built for 2-second blocks needs `1,800 / 2 + 1 = 901` observations for a 1,800 s window:
    /// on a pool with a 901-slot buffer it lists and is Live with `twapMinObservations = 901`, and `checkConfig`
    /// refuses 900 and 151; the 12-second implementation refuses 901 for the same window and accepts 151.
    function test_TEST_264_twapBufferSizedWithTheBlockTime() public {
        _deployClMarket(_usdcUsdt());
        LPOracleCL ethereum = oracle;
        IClPool base = _createPool(token0, token1, 500, price0, price1, 901, 1e15);
        _touch(base);
        _next(block.timestamp + 3600);
        _touch(base);
        _setPrices(ONE, ONE);
        OracleConfig memory c = _config();
        c.twapMinObservations = 901;
        store.setConfig(c);
        LPOracleCL impl = LPOracleCLDeployer.deploy(tl, 2, POKE_FLOOR, POKE_CEILING, false, 7);
        InitParams memory p = _params();
        p.config = c;
        p.market = abi.encode(address(base), int24(-10), int24(10), uint256(0));
        LPOracleCL onBase =
            LPOracleCL(address(new ERC1967Proxy(address(impl), abi.encodeCall(ILPOracle.initialize, (p)))));
        assertEq(uint8(onBase.getPriceState().state), uint8(PriceState.Live), "901 observations at 2 s: Live");
        assertEq(onBase.checkConfig(c), 0, "901 accepted");
        c.twapMinObservations = 900;
        assertTrue(onBase.checkConfig(c) & (1 << (SHIFT + 1)) != 0, "900 refused at 2 s");
        c.twapMinObservations = 151;
        assertTrue(onBase.checkConfig(c) & (1 << (SHIFT + 1)) != 0, "151 refused at 2 s");
        c.twapMinObservations = 901;
        assertTrue(ethereum.checkConfig(c) & (1 << (SHIFT + 1)) != 0, "901 refused at 12 s");
        c.twapMinObservations = 151;
        assertEq(ethereum.checkConfig(c) & (1 << (SHIFT + 1)), 0, "151 accepted at 12 s");
    }

    // ─── TEST-265: the six-word slot0 ───

    // TEST-265 verifies: REQ-AMM-SLIP-003, REQ-ORACLE-103, REQ-ORACLE-026
    // Sources: 5.1 TEST-265 (LPOracle part: `slot0()` returns 6 fields and the reentrancy flag is read from its own
    // position)
    /// @notice An LPOracle built for six-word `slot0` (Slipstream's layout: no fee-protocol word, so `unlocked` is
    /// word 5) reads a pool answering six words: `unlocked = 1` is Live, `unlocked = 0` is the pool lock (reason bit 17,
    /// the accepted price served) and a value of 2 is a failed read. The seven-word implementation reads the same
    /// six-word answer as malformed, so a pool of the other layout is never priced.
    function test_TEST_265_sixWordSlot0ReadsTheFlagFromItsOwnWord() public {
        _deployClMarket(_ethUsdc());
        IClPool realPool = pool;
        ClPoolFaultShim shim = new ClPoolFaultShim(address(realPool));
        (uint160 sqrtP, int24 tick,, uint16 card,,,) = realPool.slot0();
        shim.setReply(IClPool.slot0.selector, _six(sqrtP, tick, card, 1));
        pool = IClPool(address(shim));
        implementation = LPOracleCLDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 6);
        LPOracleCL six = LPOracleCL(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(ILPOracle.initialize, (_params()))))
        );
        PriceStateView memory v = six.getPriceState();
        assertEq(uint8(v.state), uint8(PriceState.Live), "unlocked in word 5: Live");
        (uint256 accepted,) = six.lastAcceptedPrice();
        shim.setReply(IClPool.slot0.selector, _six(sqrtP, tick, card, 0));
        v = six.getPriceState();
        assertTrue(_has(v.reasons, POOL_LOCKED_BIT), "locked in word 5");
        assertEq(uint256(v.answer), accepted, "the accepted price is served");
        shim.setReply(IClPool.slot0.selector, _six(sqrtP, tick, card, 2));
        v = six.getPriceState();
        assertTrue(_has(v.reasons, 1), "a flag of 2 is a failed read");
        shim.setReply(IClPool.slot0.selector, _six(sqrtP, tick, card, 1));
        LPOracleCL seven = LPOracleCLDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7);
        vm.expectRevert();
        new ERC1967Proxy(address(seven), abi.encodeCall(ILPOracle.initialize, (_params())));
    }

    function _six(
        uint160 sqrtP,
        int24 tick,
        uint16 card,
        uint256 unlocked
    ) internal pure returns (bytes memory) {
        return abi.encode(uint256(sqrtP), int256(tick), uint256(0), uint256(card), uint256(card), unlocked);
    }

    // ─── TEST-071: a price that would round to 0 cannot be listed ───

    // TEST-071 verifies: REQ-ORACLE-049, REQ-CONFIG-022, MATH-UO-05
    // Sources: 5.1 TEST-071 (a market whose per-token price would round to 0 cannot be listed)
    /// @notice An 18-decimal USD feed whose minimum answer normalises to 0 at 8 decimals (`10^10 - 1`) would let a
    /// token's quote round to 0: `checkConfig` sets `CHECK_LEG_BOUNDS` and `initialize` of a market with it reverts
    /// `ConfigCheckFailed`. At `10^10`, the smallest minimum that normalises to 1, the bit is clear.
    function test_TEST_071_tokenPriceRoundingToZeroCannotBeListed() public {
        _deployClMarket(_usdcUsdt());
        OracleFeedMock low = new OracleFeedMock(18, 1e10 - 1, 1e28);
        low.push(1e18, block.timestamp);
        OracleConfig memory c = _config();
        c.tokens[0].routes[1].legs[0] = _leg18(address(low), 1e10 - 1);
        uint256 failed = oracle.checkConfig(c);
        assertTrue(failed & LPOracleCodes.CHECK_LEG_BOUNDS != 0, "a minimum normalising to 0 is refused");
        InitParams memory p = _params();
        p.config = c;
        store.setConfig(c);
        vm.expectPartialRevert(ILPOracleErrors.ConfigCheckFailed.selector);
        new ERC1967Proxy(address(implementation), abi.encodeCall(ILPOracle.initialize, (p)));
        OracleFeedMock ok = new OracleFeedMock(18, 1e10, 1e28);
        ok.push(1e18, block.timestamp);
        c.tokens[0].routes[1].legs[0] = _leg18(address(ok), 1e10);
        assertEq(oracle.checkConfig(c) & LPOracleCodes.CHECK_LEG_BOUNDS, 0, "10^10 normalises to 1: accepted");
    }

    function _leg18(
        address feed,
        int128 minAnswer
    ) internal pure returns (OracleLeg memory) {
        return OracleLeg({
            aggregator: feed,
            decimals: 18,
            heartbeat: 86_400,
            heartbeatMargin: 1800,
            feedDeviationThresholdBps: 25,
            minAnswer: minAnswer,
            maxAnswer: 1e28,
            borrowPriceMaxAge: MAX_AGE,
            liquidationPriceMaxAge: MAX_AGE
        });
    }
}
