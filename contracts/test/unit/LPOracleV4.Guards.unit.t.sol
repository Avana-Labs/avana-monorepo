// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV4PoolKey} from "../../src/interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {IUniswapV3Pool} from "../../src/interfaces/external/uniswap/IUniswapV3Pool.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {ILPOracleErrors} from "../../src/oracle/lp-oracle/ILPOracleErrors.sol";
import {LPOracleCLModuleLogic} from "../../src/oracle/lp-oracle/LPOracleCLModuleLogic.sol";
import {LPOracleCodes} from "../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {LPOracleV4} from "../../src/oracle/lp-oracle/LPOracleV4.sol";
import {LPOracleV4ModuleLogic} from "../../src/oracle/lp-oracle/LPOracleV4ModuleLogic.sol";
import {ClPriceStateView} from "../../src/oracle/lp-oracle/types/ClPriceStateView.sol";
import {InitParams} from "../../src/oracle/lp-oracle/types/InitParams.sol";
import {LPOracleLogicSet} from "../../src/oracle/lp-oracle/types/LPOracleLogicSet.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LPOracleV4Fixture} from "../utils/fixtures/LPOracleV4Fixture.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice The v4 LPOracle module's guards: deployment checks, every refusal of the market encoding at `initialize`,
/// failed PoolManager and reference-pool reads, an unavailable TWAP, a stable quote above its ceiling, the listing bit
/// of an unreadable pool and the report of an unavailable check.
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

    // ─── Reads ───

    // TEST-335 verifies: REQ-AMM-V4-003, REQ-AMM-V4-011, REQ-ORACLE-016
    function test_TEST_335_failedPoolManagerReadsFailTheMarket() public {
        vm.mockCallRevert(address(pm), abi.encodeWithSignature("exttload(bytes32)"), "");
        _assertState(PriceState.Cached);
        vm.clearMockedCalls();
        vm.mockCallRevert(address(pm), abi.encodeWithSignature("extsload(bytes32)"), "");
        _assertState(PriceState.Cached);
        uint256 failed = oracle.checkConfig(_config());
        assertTrue(failed & ((1 << 8) << LPOracleCodes.MODULE_CHECKS_SHIFT) != 0, "V4_CHECK_POOL");
        vm.clearMockedCalls();
    }

    // TEST-335 verifies: REQ-AMM-V4-005, REQ-ORACLE-014, REQ-ORACLE-104
    function test_TEST_335_unavailableReferenceTwapIsDrifting() public {
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

    // TEST-335 verifies: SPEC-AMM-V4-002, REQ-ORACLE-104
    function test_TEST_335_stableAboveItsCeilingUsesTheQuote() public {
        vm.warp(block.timestamp + 1);
        _setPrices(price0, 101_000_000);
        PriceStateView memory v = _state();
        assertTrue(v.reasons & LPOracleCodes.CONSISTENCY_DEVIATION != 0, "the uncapped quote moves the reference tick");
        ClPriceStateView memory r = oracle.getClPriceState();
        assertGt(r.tickDeviation, TOLERANCE);
    }
}
