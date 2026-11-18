// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PositionProxy} from "../../src/proxy/position-proxy/PositionProxy.sol";
import {DriftReason} from "../../src/types/MarketTypes.sol";
import {PriceState} from "../../src/types/OracleTypes.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModuleBorrowUnitTest
/// @notice `preBorrowCheck` and `preWithdrawCheck`: scope, pokes, price gates, Aave pauses and freezes, drift, Hub
/// shares, liquidation halts, breakers and the sequencer gate, in the order of 2.7 Borrow-side checks.
contract RiskModuleBorrowUnitTest is RiskModuleFixture {
    function setUp() public {
        _deployRiskWorld();
        _enableUsdcDebt();
        _debt(1.5e18, 1000);
    }

    function _borrow(
        uint256 r
    ) internal {
        riskModule.preBorrowCheck(address(proxy), r, 1);
    }

    // TEST-028 verifies: REQ-ADAPTER-024, REQ-RISK-056, REQ-RISK-077, INV-023, INV-024
    // Sources: 2.7 LIFECYCLE step 3
    function test_TEST_028_borrowPasses() public {
        _borrow(GHO_RESERVE);
        _borrow(USDC_RESERVE);
        riskModule.preWithdrawCheck(address(proxy));
    }

    // TEST-278 verifies: REQ-RISK-077, REQ-RISK-083, REQ-RISK-008
    function test_TEST_278_noMinimumDebt() public {
        rSpoke.setAccount(address(proxy), 0, 0, 0);
        rSpoke.setStatus(address(proxy), GHO_RESERVE, false, false);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
    }

    // TEST-028 verifies: REQ-ADAPTER-011, REQ-ADAPTER-013, REQ-ADAPTER-014, REQ-ADAPTER-022, INV-024
    function test_TEST_028_scope() public {
        address other = makeAddr("otherSpoke");
        PositionProxy foreign = new PositionProxy(address(adapter), wallet, other, mid);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.UnknownSpoke.selector, other));
        riskModule.preBorrowCheck(address(foreign), GHO_RESERVE, 1);
        // A collateral reserve that is not the account's market.
        rSpoke.setStatus(address(proxy), USDC_RESERVE, true, false);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.UnknownCollateral.selector, USDC_RESERVE));
        _borrow(GHO_RESERVE);
        rSpoke.setStatus(address(proxy), USDC_RESERVE, false, false);
        // A borrowed reserve the registry has not enabled.
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, 0, DriftReason.BorrowedUnapprovedReserve)
        );
        _borrow(3);
        // An enabled reserve whose Aave reserve no longer matches its definition.
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (address(gho), address(hub), uint16(GHO_ASSET), 6);
        IAaveV4Spoke.ReserveConfig memory c;
        c.borrowable = true;
        spoke.setReserve(GHO_RESERVE, r, c, IAaveV4Spoke.DynamicReserveConfig(0, 0, 0));
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, 0, DriftReason.DebtReserveMismatch)
        );
        _borrow(USDC_RESERVE);
    }

    // TEST-158 verifies: REQ-ADAPTER-061, REQ-ADAPTER-062, REQ-RISK-061, INV-060, REQ-ACCESS-130
    function test_TEST_158_aavePauses() public {
        IAaveV4Spoke.ReserveConfig memory c;
        (c.borrowable, c.paused) = (true, true);
        rSpoke.setConfig(GHO_RESERVE, c);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.DebtReservePaused.selector, GHO_RESERVE));
        _borrow(GHO_RESERVE);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.DebtReservePaused.selector, GHO_RESERVE));
        riskModule.preWithdrawCheck(address(proxy));
        c.paused = false;
        rSpoke.setConfig(GHO_RESERVE, c);
        IAaveV4Spoke.ReserveConfig memory v;
        v.paused = true;
        rSpoke.setConfig(VT_RESERVE, v);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.AaveReservePaused.selector, VT_RESERVE));
        _borrow(GHO_RESERVE);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.AaveReservePaused.selector, VT_RESERVE));
        riskModule.preWithdrawCheck(address(proxy));
    }

    // TEST-155 verifies: REQ-ADAPTER-019, REQ-ADAPTER-025, REQ-ADAPTER-056, REQ-PROXY-079, INV-060, REQ-ACCESS-036, REQ-RISK-032, REQ-RISK-034
    function test_TEST_155_frozenAndOffboardingBlockBorrowOnly() public {
        IAaveV4Spoke.ReserveConfig memory v;
        v.frozen = true;
        rSpoke.setConfig(VT_RESERVE, v);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.ReserveFrozen.selector, VT_RESERVE));
        _borrow(GHO_RESERVE);
        riskModule.preWithdrawCheck(address(proxy));
        // Frozen with no supplied shares does not block.
        rSpoke.setSupplied(address(proxy), VT_RESERVE, 0);
        _borrow(GHO_RESERVE);
        rSpoke.setConfig(VT_RESERVE, IAaveV4Spoke.ReserveConfig(0, false, false, false, false));
        vm.prank(address(timelock));
        registry.setMarketOffboarding(mid);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.MarketOffboarding.selector, mid));
        _borrow(GHO_RESERVE);
        riskModule.preWithdrawCheck(address(proxy));
    }

    // TEST-033 verifies: REQ-ADAPTER-020, REQ-ADAPTER-030, REQ-RISK-069, INV-029
    function test_TEST_033_driftOnAccountKey() public {
        // The account's own dynamic key carries a liquidation fee while the latest key is clean.
        IAaveV4Spoke.DynamicReserveConfig memory d;
        (d.collateralFactor, d.maxLiquidationBonus, d.liquidationFee) = (3000, 10_500, 100);
        rSpoke.setDynamicAt(VT_RESERVE, 7, d);
        rSpoke.setUserKey(address(proxy), VT_RESERVE, 7);
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, mid, DriftReason.LiquidationFeeNonZero)
        );
        _borrow(GHO_RESERVE);
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, mid, DriftReason.LiquidationFeeNonZero)
        );
        riskModule.preWithdrawCheck(address(proxy));
        // The pledge-side drift check reads only the latest key.
        riskModule.checkAaveConfig(address(spoke), _ids());
    }

    // TEST-028 verifies: REQ-ADAPTER-021, REQ-ADAPTER-058
    function test_TEST_028_hubSharesNotEqualAssets() public {
        rHub.setAdded(VT_ASSET, 1000, 999);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HubSharesNotEqualAssets.selector, mid));
        _borrow(GHO_RESERVE);
    }

    // TEST-068 verifies: REQ-ADAPTER-010, REQ-RISK-062, REQ-RISK-071, REQ-ADAPTER-054, REQ-ACCESS-075, REQ-ROUTE-021
    // Sources: 2.7 REQ-RISK-071 example (freezing the last committed operator)
    function test_TEST_068_liquidationHalts() public {
        swap.setKeepers(0);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.LiquidationHalted.selector, mid));
        _borrow(GHO_RESERVE);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.LiquidationHalted.selector, mid));
        riskModule.preWithdrawCheck(address(proxy));
        swap.setKeepers(1);
        // USDT has no usable route into USDC once both routes are gone; USDC itself needs none.
        vm.startPrank(address(timelock));
        registry.disableRoute(mid, address(usdt), address(usdc), 0);
        registry.disableRoute(mid, address(usdt), address(usdc), 1);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.DebtLiquidationHalted.selector, USDC_RESERVE));
        _borrow(USDC_RESERVE);
        _borrow(GHO_RESERVE);
    }

    // TEST-228 verifies: REQ-RISK-065, REQ-RISK-073, SPEC-BRK-008, INV-081, REQ-ACCESS-166, REQ-ACCESS-084
    function test_TEST_228_breakersOnBorrowAndWithdraw() public {
        vm.prank(emergencyGuardian);
        registry.tripDebtBreaker(address(spoke), USDC_RESERVE);
        // A GHO borrow passes; a USDC borrow reverts.
        _borrow(GHO_RESERVE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtBreakerTripped.selector, address(spoke), USDC_RESERVE, BreakerReasons.MANUAL
            )
        );
        _borrow(USDC_RESERVE);
        // Withdraw-with-debt checks the debt breaker of every reserve held.
        riskModule.preWithdrawCheck(address(proxy));
        rSpoke.setStatus(address(proxy), USDC_RESERVE, false, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtBreakerTripped.selector, address(spoke), USDC_RESERVE, BreakerReasons.MANUAL
            )
        );
        riskModule.preWithdrawCheck(address(proxy));
        vm.prank(emergencyGuardian);
        registry.tripMarketBreaker(mid);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, mid, BreakerReasons.MANUAL));
        _borrow(GHO_RESERVE);
    }

    // TEST-028 verifies: REQ-ADAPTER-013, REQ-RISK-009, INV-024
    function test_TEST_028_marketNotActiveOrOffboarding() public {
        // A proxy of a market that is still Registered, and of a market without a record.
        uint256 registered = _listRegisteredMarket();
        PositionProxy p = new PositionProxy(address(adapter), wallet, address(spoke), registered);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.UnknownCollateral.selector, 0));
        riskModule.preBorrowCheck(address(p), GHO_RESERVE, 1);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.UnknownCollateral.selector, 0));
        riskModule.preWithdrawCheck(address(p));
        p = new PositionProxy(address(adapter), wallet, address(spoke), 999);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.UnknownCollateral.selector, 0));
        riskModule.preWithdrawCheck(address(p));
    }

    function _ids() internal view returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = mid;
    }
}
