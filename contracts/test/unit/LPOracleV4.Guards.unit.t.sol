// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV4PoolKey} from "../../src/interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {IUniswapV3Pool} from "../../src/interfaces/external/uniswap/IUniswapV3Pool.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {ILPOracleErrors} from "../../src/oracle/lp-oracle/ILPOracleErrors.sol";
import {LPOracleCLModuleLogic} from "../../src/oracle/lp-oracle/LPOracleCLModuleLogic.sol";
import {LPOracleCLPool} from "../../src/oracle/lp-oracle/LPOracleCLPool.sol";
import {LPOracleStorage} from "../../src/oracle/lp-oracle/LPOracleStorage.sol";
import {LPOracleCodes} from "../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {LPOracleV4} from "../../src/oracle/lp-oracle/LPOracleV4.sol";
import {LPOracleV4Module} from "../../src/oracle/lp-oracle/LPOracleV4Module.sol";
import {LPOracleV4ModuleLogic} from "../../src/oracle/lp-oracle/LPOracleV4ModuleLogic.sol";
import {LPPriceMath} from "../../src/oracle/lp-oracle/LPPriceMath.sol";
import {ClPriceStateView} from "../../src/oracle/lp-oracle/types/ClPriceStateView.sol";
import {InitParams} from "../../src/oracle/lp-oracle/types/InitParams.sol";
import {LPOracleLogicSet} from "../../src/oracle/lp-oracle/types/LPOracleLogicSet.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LPOracleV4Fixture} from "../utils/fixtures/LPOracleV4Fixture.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice The v4 module on its own storage, initialized by its real market parser, exposing the pool hook and the
/// report on any input vectors: the oracle's evaluation never passes a valid price with an invalid quote, nor a priced
/// report after a failed PoolManager read, so those branches are reached only here.
contract V4ModuleProbe is LPOracleV4Module {
    constructor(
        address wrappedNative
    )
        LPOracleStorage(address(0x7173), 12, 900_000, 3_000_000, false)
        LPOracleCLPool(7)
        LPOracleV4Module(wrappedNative)
    {}

    function init(
        bytes calldata market,
        address[] calldata tokens,
        uint8[] calldata decimals
    ) external returns (bool ok) {
        Layout storage $ = _s();
        delete $.tokens;
        delete $.tokenDecimals;
        for (uint256 i = 0; i < tokens.length; ++i) {
            $.tokens.push(tokens[i]);
            $.tokenDecimals.push(decimals[i]);
        }
        ok = _initMarket(market, tokens);
    }

    function poolCheck(
        uint256[] memory quotes,
        uint256[] memory prices,
        uint32 window,
        uint16 toleranceBps
    ) external view returns (PoolCheck memory) {
        return _poolCheck(quotes, prices, window, toleranceBps);
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

/// @notice The v4 LPOracle module's guards: deployment checks, every refusal of the market encoding at `initialize`,
/// failed PoolManager and reference-pool reads, an unavailable TWAP, a stable quote above its ceiling, the listing bit
/// of an unreadable pool, the report of an unavailable check, and the module's pool hook and report on inputs the
/// evaluation never passes (a valid price with an invalid quote, a priced report after a failed PoolManager read).
/// forge-config: default.isolate = false
contract LPOracleV4GuardsUnitTest is LPOracleV4Fixture {
    function setUp() public {
        _deployV4Market();
    }

    // ─── Deployment ───

    // TEST-331 verifies: REQ-ORACLE-080
    function test_TEST_331_deploymentRefusesAMismatchedModule() public {
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.MarketMismatch.selector, uint256(0)));
        new LPOracleV4ModuleLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, address(0));
        address v4m = address(new LPOracleV4ModuleLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, address(weth)));
        LPOracleLogicSet memory logics = _logics(v4m);
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.MarketMismatch.selector, uint256(0)));
        new LPOracleV4(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, v4m, logics, address(usdc));
        address clm = address(new LPOracleCLModuleLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7));
        LPOracleLogicSet memory clLogics = _logics(clm);
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.MarketMismatch.selector, uint256(0)));
        new LPOracleV4(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, clm, clLogics, address(weth));
    }

    function _logics(
        address m
    ) internal returns (LPOracleLogicSet memory) {
        return _deployImplementationLogics(m);
    }

    // ─── initialize ───

    function _refused(
        bytes memory market
    ) internal {
        InitParams memory p = _params();
        p.market = market;
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.MarketMismatch.selector, MARKET));
        new ERC1967Proxy(address(implementation), abi.encodeCall(ILPOracle.initialize, (p)));
    }

    // TEST-331 verifies: REQ-ORACLE-058, REQ-AMM-V4-001, REQ-AMM-V4-007
    function test_TEST_331_initializeRefusesEveryMalformedMarket() public {
        UniswapV4PoolKey memory k = _v4Key();
        _refused(hex"00");
        // No code at the PoolManager.
        _refused(abi.encode(makeAddr("noPm"), k, LOWER, UPPER, uint256(0), address(ref)));
        // Currencies other than the market's tokens.
        UniswapV4PoolKey memory other = _v4Key();
        other.currency1 = address(weth);
        _refused(_market(other, address(ref)));
        // A fee word above 24 bits.
        bytes memory m = _market(k, address(ref));
        assembly {
            mstore(add(m, add(32, 96)), shl(30, 1))
        }
        _refused(m);
        // Spacing 0, a unit exponent above the maximum, an unusable range.
        UniswapV4PoolKey memory flat = _v4Key();
        flat.tickSpacing = 0;
        _refused(_market(flat, address(ref)));
        _refused(abi.encode(address(pm), k, LOWER, UPPER, uint256(19), address(ref)));
        _refused(abi.encode(address(pm), k, UPPER, LOWER, uint256(0), address(ref)));
        // An address word above 160 bits.
        bytes memory wide = _market(k, address(ref));
        assembly {
            mstore(add(wide, 32), not(0))
        }
        _refused(wide);
        // An uninitialized pool.
        UniswapV4PoolKey memory fresh = _v4Key();
        fresh.fee = 3000;
        fresh.tickSpacing = 60;
        _refused(abi.encode(address(pm), fresh, int24(-206_940), int24(-194_040), uint256(0), address(ref)));
    }

    // TEST-331 verifies: REQ-ORACLE-058, REQ-AMM-V4-009
    /// @notice A market token reporting more than 18 decimals is refused at `initialize`, as the LPVault refuses it at
    /// listing.
    function test_TEST_331_initializeRefusesTokensAboveEighteenDecimals() public {
        vm.mockCall(address(weth), abi.encodeWithSignature("decimals()"), abi.encode(uint8(19)));
        _refused(_market(_v4Key(), address(ref)));
        vm.clearMockedCalls();
    }

    // ─── Reads ───

    // TEST-343 verifies: REQ-AMM-V4-003, REQ-AMM-V4-011, REQ-ORACLE-016
    function test_TEST_343_failedPoolManagerReadsFailTheMarket() public {
        vm.mockCallRevert(address(pm), abi.encodeWithSignature("exttload(bytes32)"), "");
        _assertState(PriceState.Cached);
        vm.clearMockedCalls();
        vm.mockCallRevert(address(pm), abi.encodeWithSignature("extsload(bytes32)"), "");
        _assertState(PriceState.Cached);
        uint256 failed = oracle.checkConfig(_config());
        assertTrue(failed & ((1 << 8) << LPOracleCodes.MODULE_CHECKS_SHIFT) != 0, "V4_CHECK_POOL");
        vm.clearMockedCalls();
    }

    // TEST-343 verifies: REQ-AMM-V4-005, REQ-ORACLE-014, REQ-ORACLE-104
    function test_TEST_343_unavailableReferenceTwapIsDrifting() public {
        vm.mockCallRevert(address(ref), abi.encodeWithSelector(IUniswapV3Pool.observe.selector), "OLD");
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Drifting));
        assertTrue(v.reasons & LPOracleCodes.CONSISTENCY_UNAVAILABLE != 0);
        ClPriceStateView memory r = oracle.getClPriceState();
        assertEq(r.tickDeviation, 0, "no deviation reported without the TWAP");
        vm.clearMockedCalls();
        // A reference buffer too short for the window.
        bytes memory slot0 = abi.encode(uint160(1 << 96), int24(0), uint16(0), uint16(1), uint16(1), uint8(0), true);
        vm.mockCall(address(ref), abi.encodeWithSelector(IUniswapV3Pool.slot0.selector), slot0);
        assertTrue(_state().reasons & LPOracleCodes.CONSISTENCY_UNAVAILABLE != 0, "cardinality");
        vm.clearMockedCalls();
    }

    // TEST-343 verifies: REQ-ORACLE-016, REQ-ORACLE-104, SPEC-AMM-V4-002
    /// @notice With every feed past its maximum age the market is not Live and the CL report carries no mean or
    /// reference tick.
    function test_TEST_343_staleQuotesReportNoTicks() public {
        vm.warp(block.timestamp + MAX_AGE + 1);
        PriceStateView memory v = _state();
        assertTrue(v.state != PriceState.Live, "not live without fresh quotes");
        ClPriceStateView memory r = oracle.getClPriceState();
        assertEq(r.meanTick, 0, "no mean tick");
        assertEq(r.tickRef, 0, "no reference tick");
    }

    // TEST-343 verifies: SPEC-AMM-V4-002, REQ-ORACLE-104
    function test_TEST_343_stableAboveItsCeilingUsesTheQuote() public {
        vm.warp(vm.getBlockTimestamp() + 1);
        _setPrices(price0, 101_000_000);
        PriceStateView memory v = _state();
        assertTrue(v.reasons & LPOracleCodes.CONSISTENCY_DEVIATION != 0, "the uncapped quote moves the reference tick");
        ClPriceStateView memory r = oracle.getClPriceState();
        assertGt(r.tickDeviation, TOLERANCE);
    }

    // ─── Module hooks on chosen inputs ───

    function _probe() internal returns (V4ModuleProbe probe) {
        probe = new V4ModuleProbe(address(weth));
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(weth), address(usdc));
        uint8[] memory decimals = new uint8[](2);
        (decimals[0], decimals[1]) = (18, 6);
        assertTrue(probe.init(_market(_v4Key(), address(ref)), tokens, decimals), "market accepted");
    }

    function _pair(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256[] memory v) {
        v = new uint256[](2);
        (v[0], v[1]) = (a, b);
    }

    // TEST-343 verifies: REQ-AMM-V4-003, SPEC-AMM-V4-002, REQ-ORACLE-104
    /// @notice With valid valuation prices but a zero quote, or a quote above `MAX_ROUTE_ANSWER`, the v4 pool hook
    /// reads the locked PoolManager and the clamp flag and stops before the consistency check: available, pass and
    /// deviation stay 0. With both quotes the check runs and passes at the pool's own price.
    function test_TEST_343_poolCheckWithoutAQuoteSkipsConsistency() public {
        V4ModuleProbe probe = _probe();
        uint256[] memory prices = _pair(ETH, USD);
        LPOracleStorage.PoolCheck memory p = probe.poolCheck(_pair(0, USD), prices, WINDOW, TOLERANCE);
        assertTrue(p.readOk, "PoolManager read");
        assertFalse(p.locked, "PoolManager locked");
        assertFalse(p.clamped, "inside the range");
        assertFalse(p.available, "no consistency check");
        assertFalse(p.pass, "no pass");
        assertEq(p.deviationBps, 0, "no deviation");
        p = probe.poolCheck(_pair(ETH, LPPriceMath.MAX_ROUTE_ANSWER + 1), prices, WINDOW, TOLERANCE);
        assertFalse(p.available, "quote above MAX_ROUTE_ANSWER: no consistency check");
        p = probe.poolCheck(prices, prices, WINDOW, TOLERANCE);
        assertTrue(p.available, "both quotes: available");
        assertTrue(p.pass, "at the pool's price");
    }

    // TEST-343 verifies: SPEC-AMM-V4-002, REQ-ORACLE-104
    /// @notice When the PoolManager's `slot0` read fails on a priced report, the deviation is the reference TWAP's
    /// distance from `tickRef` alone; the spot leg counts 0. With the read back, the larger of the two distances.
    function test_TEST_343_clReportWithoutTheV4SpotUsesTheTwapAlone() public {
        V4ModuleProbe probe = _probe();
        uint256[] memory prices = _pair(ETH, USD);
        vm.mockCallRevert(address(pm), abi.encodeWithSignature("extsload(bytes32)"), "");
        ClPriceStateView memory r = probe.clReport(true, prices, prices, WINDOW, TOLERANCE);
        vm.clearMockedCalls();
        assertTrue(r.meanTick != 0, "mean tick");
        int256 twapGap = int256(r.meanTick) - int256(r.tickRef);
        assertEq(uint256(r.tickDeviation), uint256(twapGap < 0 ? -twapGap : twapGap), "TWAP distance only");
        ClPriceStateView memory both = probe.clReport(true, prices, prices, WINDOW, TOLERANCE);
        assertEq(both.tickRef, r.tickRef, "same reference");
        assertGe(both.tickDeviation, r.tickDeviation, "spot leg back");
    }

    // ─── Range check ───

    // TEST-331 verifies: REQ-ORACLE-105, REQ-ORACLE-058, REQ-AMM-V4-007
    /// @notice A v4 key of tick spacing 60 against its fee-500 Uniswap v3 reference pool (spacing 10) lists, and its
    /// `checkConfig` leaves `CL_CHECK_RANGE` (bit 16) clear: the range check reached through `super._clListingChecks` is
    /// the v4 module's, at the key's own spacing. The concentrated-liquidity check it overrides compares the reference
    /// pool's `tickSpacing()` with the stored one and would set the bit, so `initialize` would revert.
    function test_TEST_331_rangeCheckUsesTheV4KeysSpacingNotTheReferencePools() public {
        int24 upper60 = -193_980;
        _initPool(_key(address(0), address(usdc), 500, 60), ETH, USD, 18, 6);
        assertEq(IUniswapV3Pool(address(ref)).tickSpacing(), 10, "the reference pool's spacing");
        InitParams memory p = _params();
        p.market = abi.encode(
            address(pm),
            UniswapV4PoolKey(address(0), address(usdc), 500, 60, address(0)),
            LOWER,
            upper60,
            uint256(0),
            ref
        );
        LPOracleV4 wide =
            LPOracleV4(address(new ERC1967Proxy(address(implementation), abi.encodeCall(ILPOracle.initialize, (p)))));
        uint256 rangeBit = (1 << 0) << LPOracleCodes.MODULE_CHECKS_SHIFT;
        assertEq(wide.checkConfig(_config()) & rangeBit, 0, "CL_CHECK_RANGE clear at the v4 spacing");
        assertEq(oracle.checkConfig(_config()) & rangeBit, 0, "and for the spacing-10 market");
    }
}
