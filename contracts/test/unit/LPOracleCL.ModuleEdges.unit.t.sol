// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {ILPOracleErrors} from "../../src/oracle/lp-oracle/ILPOracleErrors.sol";
import {LPOracleCLModuleCaller} from "../../src/oracle/lp-oracle/LPOracleCLModuleCaller.sol";
import {LPOracleCLModuleLogic} from "../../src/oracle/lp-oracle/LPOracleCLModuleLogic.sol";
import {LPOracleCLPool} from "../../src/oracle/lp-oracle/LPOracleCLPool.sol";
import {LPOracleStorage} from "../../src/oracle/lp-oracle/LPOracleStorage.sol";
import {LPPriceMath} from "../../src/oracle/lp-oracle/LPPriceMath.sol";
import {ClPriceStateView} from "../../src/oracle/lp-oracle/types/ClPriceStateView.sol";
import {OracleConfig} from "../../src/types/OracleConfig.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {LPOracleCLFixture} from "../utils/fixtures/LPOracleCLFixture.sol";
import {LPOracleCLMathHarness} from "../utils/harness/LPOracleCLMathHarness.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The module's math harness with the market's pool and tokens set, exposing the pool hook, the `PoolTwap` hook
/// and the report on any input vectors.
contract ClModuleProbe is LPOracleCLMathHarness {
    function setPool(
        address pool,
        address t0,
        address t1
    ) external {
        _cl().pool = pool;
        Layout storage $ = _s();
        delete $.tokens;
        $.tokens.push(t0);
        $.tokens.push(t1);
    }

    function poolCheck(
        uint256[] memory quotes,
        uint256[] memory prices,
        uint32 window,
        uint16 toleranceTicks
    ) external view returns (PoolCheck memory) {
        return _poolCheck(quotes, prices, window, toleranceTicks);
    }

    function poolTwapPrice(
        uint256 index,
        bytes32 poolRef,
        uint32 window,
        uint256[] memory quotes
    ) external view returns (bool ok, uint256 value) {
        SecondSource memory source;
        (source.poolRef, source.twapWindow) = (poolRef, window);
        (ok, value) = _poolTwapPrice(index, source, quotes);
    }

    function clReport(
        bool priced,
        uint256[] memory quotes,
        uint256[] memory prices,
        uint32 window,
        uint16 toleranceTicks
    ) external view returns (ClPriceStateView memory) {
        return _clReport(priced, quotes, prices, window, toleranceTicks);
    }
}

/// @notice A logic contract's pricing-hook caller on its own storage, delegating to a real `LPOracleCLModuleLogic`.
contract ClModuleCallerProbe is LPOracleCLModuleCaller {
    constructor(
        address moduleLogic
    )
        LPOracleStorage(address(0x7173), 12, 900_000, 3_000_000, false)
        LPOracleCLPool(7)
        LPOracleCLModuleCaller(moduleLogic)
    {}

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
    ) external view returns (bool ok, uint256[] memory amounts) {
        uint256[] memory prices = new uint256[](2);
        (prices[0], prices[1]) = (p0, p1);
        (ok, amounts) = _composition(units, prices);
    }

    function listingChecks(
        OracleConfig calldata config,
        uint256[] memory quotes
    ) external view returns (uint256) {
        return _listingChecks(config, quotes);
    }
}

/// @title LPOracleCLModuleEdgesTest
/// @notice The concentrated-liquidity module's guards on inputs the core never passes, run on the module's own code:
/// the pool hook, the `PoolTwap` hook and the report on a missing quote, `SPEC-ORC-009`'s clamp to a square-root bound,
/// the shock check on an invalid quote, the TWAP quote above the `uint128` root, the mean tick of a zero window, the
/// logic contracts' hook caller on a refused composition and a short quote vector, and the module contract refusing
/// every direct call.
contract LPOracleCLModuleEdgesTest is LPOracleCLFixture {
    ClModuleProbe internal probe;

    /// @dev The ETH/USDC market, and the probe on its pool, tokens, decimals and range.
    function _probeMarket() internal {
        _deployClMarket(_ethUsdc());
        probe = new ClModuleProbe();
        probe.setMarket(token0.decimals(), token1.decimals(), tickLower, tickUpper);
        probe.setPool(address(pool), address(token0), address(token1));
    }

    function _pair(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256[] memory v) {
        v = new uint256[](2);
        (v[0], v[1]) = (a, b);
    }

    // TEST-306 verifies: REQ-ORACLE-103, SPEC-ORC-010, REQ-ORACLE-104
    /// @notice With valid valuation prices but a zero quote, the pool hook reads the unlocked pool and the clamp flag
    /// and stops before the consistency check: available, pass and deviation stay 0. Both quotes valid, the check runs
    /// and passes at the pool's own price.
    function test_TEST_306_poolCheckWithoutAQuoteSkipsConsistency() public {
        _probeMarket();
        uint256[] memory prices = _pair(price0, price1);
        LPOracleStorage.PoolCheck memory p = probe.poolCheck(_pair(0, price1), prices, WINDOW, TOLERANCE);
        assertTrue(p.readOk, "pool read");
        assertFalse(p.locked, "unlocked");
        assertFalse(p.clamped, "inside the full range");
        assertFalse(p.available, "no consistency check");
        assertFalse(p.pass, "no pass");
        assertEq(p.deviationBps, 0, "no deviation");
        p = probe.poolCheck(_pair(price0, LPPriceMath.MAX_ROUTE_ANSWER + 1), prices, WINDOW, TOLERANCE);
        assertFalse(p.available, "quote above MAX_ROUTE_ANSWER: no consistency check");
        p = probe.poolCheck(prices, prices, WINDOW, TOLERANCE);
        assertTrue(p.available, "both quotes: available");
        assertTrue(p.pass, "at the pool's price");
        assertLe(p.deviationBps, 1, "within a tick");
    }

    // TEST-306 verifies: SPEC-ORC-020, REQ-ORACLE-100
    /// @notice The `PoolTwap` hook refuses a token index above 1 and a zero quote with `(false, 0)`; on the market's
    /// pair it values one USDC at about its $1 quote.
    function test_TEST_306_poolTwapRefusesABadIndexOrQuote() public {
        _probeMarket();
        bytes32 ref = bytes32(uint256(uint160(address(pool))));
        uint256 usdc = token0.decimals() == 6 ? 0 : 1;
        uint256[] memory quotes = _pair(price0, price1);
        (bool ok, uint256 value) = probe.poolTwapPrice(2, ref, WINDOW, quotes);
        assertFalse(ok, "index 2");
        assertEq(value, 0, "no value");
        (ok, value) = probe.poolTwapPrice(usdc, ref, WINDOW, _pair(0, price1));
        assertFalse(ok, "zero quote");
        assertEq(value, 0, "no value");
        (ok, value) = probe.poolTwapPrice(usdc, ref, WINDOW, quotes);
        assertTrue(ok, "paired pool");
        assertApproxEqRel(value, 1e8, 0.001e18, "one USDC at about $1");
    }

    // TEST-306 verifies: REQ-ORACLE-104, REQ-ORACLE-042
    /// @notice The report of a priced market with a zero quote carries the oracle and used prices but no mean tick,
    /// reference or deviation; with both quotes it carries all three.
    function test_TEST_306_clReportWithoutAQuote() public {
        _probeMarket();
        uint256[] memory prices = _pair(price0, price1);
        ClPriceStateView memory r = probe.clReport(true, _pair(price0, 0), prices, WINDOW, TOLERANCE);
        assertEq(r.sqrtPriceOracleX96, _oracleSqrt(price0, price1), "oracle price");
        assertEq(r.sqrtPriceUsedX96, r.sqrtPriceOracleX96, "used price");
        assertGe(r.observationCardinality, 151, "cardinality");
        assertEq(r.meanTick, 0, "no mean tick");
        assertEq(r.tickRef, 0, "no reference");
        assertEq(r.tickDeviation, 0, "no deviation");
        r = probe.clReport(true, prices, prices, WINDOW, TOLERANCE);
        assertEq(r.tickRef, ClPriceMath.tickAtSqrtRatio(_oracleSqrt(price0, price1)), "reference");
        assertLe(r.tickDeviation, 1, "within a tick");
        assertTrue(r.meanTick != 0, "mean tick");
    }

    // TEST-305 verifies: SPEC-ORC-009, REQ-ORACLE-104
    /// @notice The clamp flag: a zero price is not a clamp (no price); `SPEC-ORC-009` moving the root to a bound is,
    /// even inside a full range. With token1 at 50 decimals, `p0 = 10^18`, `p1 = 1` give `num = 10^68 >= 2^128 * den`,
    /// so the root is `MAX_SQRT_RATIO - 1`; with token0 at 50 decimals, `p0 = 1`, `p1 = 10^18` give a root below
    /// `MIN_SQRT_RATIO`, so it is `MIN_SQRT_RATIO`. At 6 and 18 decimals the same prices are not clamped.
    function test_TEST_305_clampFlagAtTheSquareRootBounds() public {
        ClModuleProbe h = new ClModuleProbe();
        h.setMarket(6, 18, ClPriceMath.MIN_TICK, ClPriceMath.MAX_TICK);
        assertFalse(h.clampedAt(0, 1e8), "zero price: no clamp");
        assertFalse(h.clampedAt(1e18, 1), "6/18 decimals: inside the bounds");
        h.setMarket(0, 50, ClPriceMath.MIN_TICK, ClPriceMath.MAX_TICK);
        assertEq(h.oracleSqrt(1e18, 1), ClPriceMath.MAX_SQRT_RATIO - 1, "upper bound");
        assertTrue(h.clampedAt(1e18, 1), "clamped to MAX_SQRT_RATIO - 1");
        h.setMarket(50, 0, ClPriceMath.MIN_TICK, ClPriceMath.MAX_TICK);
        assertEq(h.oracleSqrt(1, 1e18), ClPriceMath.MIN_SQRT_RATIO, "lower bound");
        assertTrue(h.clampedAt(1, 1e18), "clamped to MIN_SQRT_RATIO");
    }

    // TEST-306 verifies: REQ-ORACLE-105, SPEC-ORC-009
    /// @notice The shock check refuses a quote outside `[1, MAX_ROUTE_ANSWER]` (0, or `10^18 + 1`) and holds for two
    /// $1 stables at 6 decimals.
    function test_TEST_306_shockCheckRefusesAnInvalidQuote() public {
        ClModuleProbe h = new ClModuleProbe();
        h.setMarket(6, 6, -10, 10);
        assertTrue(h.shockSqrtHolds(1e8, 1e8), "two $1 stables");
        assertFalse(h.shockSqrtHolds(0, 1e8), "zero quote");
        assertFalse(h.shockSqrtHolds(1e8, LPPriceMath.MAX_ROUTE_ANSWER + 1), "quote above MAX_ROUTE_ANSWER");
    }

    // TEST-306 verifies: REQ-ORACLE-105, SPEC-ORC-009, REQ-CONFIG-035
    /// @notice INTEG-04: WBTC (8 decimals) as token0 against an 18-decimal $1 stable passes the shock check at $184,467,
    /// $10M and the `MAX_ROUTE_ANSWER` price; the sqrt price there is computed, not clamped. The check still refuses a
    /// shocked ratio at `2^128`, which with valid quotes needs more than 36 decimals between the tokens (here 0 and 22).
    function test_TEST_306_shockCheckAdmitsWbtcAgainstAnEighteenDecimalStable() public {
        ClModuleProbe h = new ClModuleProbe();
        h.setMarket(8, 18, ClPriceMath.MIN_TICK, ClPriceMath.MAX_TICK);
        uint256[3] memory btc = [uint256(184_467e8), 10_000_000e8, LPPriceMath.MAX_ROUTE_ANSWER];
        for (uint256 i = 0; i < 3; ++i) {
            assertTrue(h.shockSqrtHolds(btc[i], 1e8), "WBTC / 18-decimal stable");
            assertFalse(h.clampedAt(btc[i], 1e8), "sqrt price not clamped");
        }
        h.setMarket(0, 22, ClPriceMath.MIN_TICK, ClPriceMath.MAX_TICK);
        assertFalse(h.shockSqrtHolds(LPPriceMath.MAX_ROUTE_ANSWER, 1), "shocked ratio at 2^128");
    }

    // TEST-306 verifies: SPEC-ORC-020
    /// @notice Above tick 443,636 the square-root ratio exceeds `2^128` and the quote goes through `ratioX128`
    /// (Uniswap `OracleLibrary.getQuoteAtTick`): at tick 600,000 (`1.0001^600000 = 1.13859e26`) one raw unit of token0
    /// buys about `1.13859e26` raw units of token1, and `10^30` raw units of token1 buy about 8,783 of token0.
    function test_TEST_306_quoteAtTickAboveTheUint128Root() public {
        ClModuleProbe h = new ClModuleProbe();
        int24 tick = 600_000;
        uint160 s = ClPriceMath.sqrtRatioAtTick(tick);
        assertGt(uint256(s), type(uint128).max, "root above 2^128");
        uint256 ratioX128 = Math.mulDiv(s, s, 1 << 64);
        uint256 up = h.quoteAtTick(tick, 1, true);
        assertEq(up, Math.mulDiv(ratioX128, 1, 1 << 128), "token0 base");
        assertApproxEqRel(up, 1.13859e26, 0.0001e18, "1.0001^600000");
        uint256 down = h.quoteAtTick(tick, 1e30, false);
        assertEq(down, Math.mulDiv(1 << 128, 1e30, ratioX128), "token1 base");
        assertApproxEqAbs(down, 8783, 1, "10^30 / 1.13859e26");
    }

    // TEST-305 verifies: SPEC-ORC-010
    /// @notice The mean tick of a zero window is unavailable; over 1,800 s a cumulative fall of 9,000 is tick -5.
    function test_TEST_305_meanTickOfAZeroWindow() public {
        ClModuleProbe h = new ClModuleProbe();
        (bool ok, int24 tick) = h.meanOf(0, -9000, 0);
        assertFalse(ok, "zero window");
        assertEq(tick, 0, "no tick");
        (ok, tick) = h.meanOf(0, -9000, 1800);
        assertTrue(ok, "1,800 s");
        assertEq(tick, -5, "-9,000 / 1,800");
    }

    // TEST-306 verifies: REQ-ORACLE-080, REQ-ORACLE-103, REQ-ORACLE-106
    // TEST-306 verifies: SPEC-ORC-006, SPEC-ORC-005
    /// @notice With unit exponent `k = 3`, a unit count below `2^128` whose liquidity `units * 10^3` reaches `2^128` is
    /// refused, and the largest count whose liquidity stays below it composes.
    function test_TEST_306_compositionRefusesLiquidityAtTheBound() public {
        ClModuleProbe h = new ClModuleProbe();
        h.setMarket(6, 6, -10, 10);
        h.setUnitExp(3);
        // 2^128 has no factor 5, so edge * 10^3 < 2^128 < (edge + 1) * 10^3.
        uint256 edge = (uint256(1) << 128) / 1e3;
        (bool ok,,) = h.composition(edge + 1, 1e8, 1e8);
        assertFalse(ok, "liquidity at 2^128 refused");
        (ok,,) = h.composition(edge, 1e8, 1e8);
        assertTrue(ok, "liquidity below 2^128 composes");
    }

    /// @notice A logic contract's hook caller, delegating to the real module: a composition the module refuses (a zero
    /// price) comes back as `(false, [])`, a valid one as the module's amounts; a quote vector of other than two
    /// entries fails every listing check without reaching the module, while two entries reach it.
    function test_TEST_306_hookCallerOnARefusedCompositionAndAShortVector() public {
        address m = address(new LPOracleCLModuleLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7));
        ClModuleCallerProbe caller = new ClModuleCallerProbe(m);
        caller.setMarket(6, 6, -10, 10);
        (bool ok, uint256[] memory amounts) = caller.composition(1e6, 0, 1e8);
        assertFalse(ok, "zero price refused");
        assertEq(amounts.length, 0, "no amounts");
        (ok, amounts) = caller.composition(1e6, 1e8, 1e8);
        ClModuleProbe h = new ClModuleProbe();
        h.setMarket(6, 6, -10, 10);
        (, uint256 a0, uint256 a1) = h.composition(1e6, 1e8, 1e8);
        assertTrue(ok, "valid composition");
        assertEq(amounts.length, 2, "two amounts");
        assertEq(amounts[0], a0, "amount0 from the module");
        assertEq(amounts[1], a1, "amount1 from the module");
        OracleConfig memory c;
        uint256[] memory one = new uint256[](1);
        one[0] = 1e8;
        assertEq(caller.listingChecks(c, one), type(uint256).max, "one quote");
        assertEq(caller.listingChecks(c, new uint256[](3)), type(uint256).max, "three quotes");
        uint256 failed = caller.listingChecks(c, _pair(1e8, 1e8));
        assertTrue(failed != type(uint256).max, "two quotes reach the module");
        assertTrue(failed & 1 != 0, "no pool: range check fails");
    }

    // TEST-306 verifies: REQ-ORACLE-105, SPEC-ORC-009
    /// @notice Through the logic contracts' hook caller, the module's listing checks set CL_CHECK_SHOCK_SQRT (bit 4)
    /// when a shocked raw ratio reaches `2^128` (a 0-decimal token0 at `MAX_ROUTE_ANSWER` against a 22-decimal token1
    /// at 1) and leave it clear for two $1 stables at 6 decimals.
    function test_TEST_306_listingChecksSetTheShockBitAtTwoToThe128() public {
        address m = address(new LPOracleCLModuleLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7));
        ClModuleCallerProbe caller = new ClModuleCallerProbe(m);
        OracleConfig memory c;
        caller.setMarket(6, 6, -10, 10);
        assertEq(caller.listingChecks(c, _pair(1e8, 1e8)) & (1 << 4), 0, "two $1 stables: clear");
        caller.setMarket(0, 22, -10, 10);
        assertTrue(
            caller.listingChecks(c, _pair(LPPriceMath.MAX_ROUTE_ANSWER, 1)) & (1 << 4) != 0, "shocked ratio at 2^128"
        );
    }

    // TEST-306 verifies: REQ-ORACLE-080, REQ-ORACLE-106
    /// @notice Called directly, outside a delegatecall, every entry point of the module contract reverts NotDelegated.
    function test_TEST_306_moduleEntryPointsRefuseDirectCalls() public {
        LPOracleCLModuleLogic m = new LPOracleCLModuleLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7);
        vm.expectRevert(ILPOracleErrors.NotDelegated.selector);
        m.composition(1e6, 1e8, 1e8);
        vm.expectRevert(ILPOracleErrors.NotDelegated.selector);
        m.poolCheck(1e8, 1e8, 1e8, 1e8, WINDOW, TOLERANCE);
        vm.expectRevert(ILPOracleErrors.NotDelegated.selector);
        m.poolTwapPrice(0, bytes32(0), WINDOW, 1e8, 1e8);
        vm.expectRevert(ILPOracleErrors.NotDelegated.selector);
        m.isOwnPool(bytes32(0));
        LPOracleCLPool.ClListingInputs memory x;
        vm.expectRevert(ILPOracleErrors.NotDelegated.selector);
        m.listingChecks(x, 1e8, 1e8);
        vm.expectRevert(ILPOracleErrors.NotDelegated.selector);
        m.clReport(true, _pair(1e8, 1e8), _pair(1e8, 1e8), WINDOW, TOLERANCE);
    }
}
