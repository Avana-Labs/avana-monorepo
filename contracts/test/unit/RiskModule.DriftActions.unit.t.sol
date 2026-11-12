// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PledgeCharge} from "../../src/policy/risk-module/types/PledgeCharge.sol";
import {AccountGateStatus} from "../../src/types/AccountGateStatus.sol";
import {DriftReason} from "../../src/types/DriftReason.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModuleDriftActionsUnitTest
/// @notice Per-action table of every Aave configuration drift the RiskModule detects: the drift check, a new-account
/// pledge, a borrow and a withdraw-with-debt revert `ConfigDrift(marketId, reason)` with the reason's market (0 for a
/// Spoke-wide reason); a top-up of an indebted account passes (REQ-RISK-069: never top-ups); the account status reports
/// the reason and both actions refused; the market breaker reports `CONFIG_DRIFT` live; `pokeConfig` latches it, so once
/// the setting is restored a borrow still reverts `BreakerTripped(m, CONFIG_DRIFT)` until an authorized reset
/// (REQ-RISK-078, REQ-ADAPTER-020, REQ-ADAPTER-036, REQ-RISK-088).
contract RiskModuleDriftActionsUnitTest is RiskModuleFixture {
    uint128 internal constant UNITS = 10_000e18;
    uint256 internal constant REASONS = 8;

    function setUp() public {
        _deployRiskWorld();
    }

    /// @dev Injects drift case `i`; returns the reason and the market it is reported on.
    function _drift(
        uint256 i
    ) internal returns (DriftReason reason, uint256 marketId) {
        IAaveV4Spoke.ReserveConfig memory c;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        (d.collateralFactor, d.maxLiquidationBonus) = (3000, 10_500);
        if (i == 0) {
            c.receiveSharesEnabled = true;
            rSpoke.setConfig(VT_RESERVE, c);
            return (DriftReason.ReceiveSharesOn, mid);
        }
        if (i == 1) {
            d.liquidationFee = 1;
            spoke.setDynamic(VT_RESERVE, d);
            return (DriftReason.LiquidationFeeNonZero, mid);
        }
        if (i == 2) {
            rHub.setReinvestment(VT_ASSET, makeAddr("controller"));
            return (DriftReason.ReinvestmentController, mid);
        }
        if (i == 3) {
            address[] memory three = new address[](3);
            (three[0], three[1], three[2]) = (address(spoke), feeReceiver, makeAddr("secondSpoke"));
            rHub.setSpokes(VT_ASSET, three);
            return (DriftReason.ExtraSpoke, mid);
        }
        if (i == 4) {
            aaveOracle.setSource(VT_RESERVE, makeAddr("otherSource"));
            return (DriftReason.PriceSource, mid);
        }
        if (i == 5) {
            d.collateralFactor = uint16(riskModule.expectedCollateralFactorBps(mid) + 1);
            spoke.setDynamic(VT_RESERVE, d);
            return (DriftReason.CollateralFactorAboveExpected, mid);
        }
        if (i == 6) {
            rSpoke.setImplSlot(bytes32(uint256(uint160(makeAddr("upgraded")))));
            return (DriftReason.SpokeImplementation, 0);
        }
        c.borrowable = true;
        rSpoke.setConfig(VT_RESERVE, c);
        return (DriftReason.DebtReserveSet, 0);
    }

    function _expectDrift(
        uint256 marketId,
        DriftReason reason
    ) internal {
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, marketId, reason));
    }

    // TEST-268 verifies: REQ-RISK-078, REQ-ADAPTER-020, REQ-ADAPTER-036, REQ-RISK-069, INV-029
    function test_TEST_268_everyDriftStopsNewRiskOnly() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = mid;
        for (uint256 i = 0; i < REASONS; ++i) {
            uint256 snap = vm.snapshotState();
            (DriftReason reason, uint256 m) = _drift(i);
            string memory tag = vm.toString(i);
            _expectDrift(m, reason);
            riskModule.checkAaveConfig(address(spoke), ids);
            // A new account (no debt) cannot pledge.
            PledgeCounters memory k = _counters();
            _expectDrift(m, reason);
            riskModule.checkPledge(wallet, address(proxy), mid, V3, bytes32(uint256(1)), UNITS, k, false);
            // The market breaker reports CONFIG_DRIFT live.
            (uint32 reasons,) = riskModule.getBreakerStatus(mid);
            assertTrue(reasons & BreakerReasons.CONFIG_DRIFT != 0, tag);
            // An indebted account: the top-up passes, new debt and withdraw-with-debt stop.
            _debt(1.5e18, 1000);
            PledgeCharge memory charge =
                riskModule.checkPledge(wallet, address(proxy), mid, V3, bytes32(uint256(1)), UNITS, k, false);
            assertEq(charge.usdCharge, 20_000e8, tag);
            _expectDrift(m, reason);
            riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
            _expectDrift(m, reason);
            riskModule.preWithdrawCheck(address(proxy));
            AccountGateStatus memory s = riskModule.getAccountGateStatus(address(proxy));
            assertEq(uint8(s.driftReason), uint8(reason), tag);
            assertEq(s.driftMarketId, m, tag);
            assertFalse(s.borrowAllowed, tag);
            assertFalse(s.withdrawWithDebtAllowed, tag);
            vm.revertToState(snap);
        }
    }

    // TEST-268 verifies: REQ-RISK-078, REQ-RISK-090, SPEC-BRK-008
    function test_TEST_268_everyDriftLatchesUntilReset() public {
        _debt(1.5e18, 1000);
        for (uint256 i = 0; i < REASONS; ++i) {
            uint256 snap = vm.snapshotState();
            (DriftReason reason,) = _drift(i);
            assertEq(uint8(riskModule.pokeConfig(address(spoke))), uint8(reason), vm.toString(i));
            (uint32 latched,) = registry.marketBreaker(mid);
            assertEq(latched, BreakerReasons.CONFIG_DRIFT);
            vm.revertToState(snap);
        }
    }

    // TEST-268 verifies: REQ-RISK-078, SPEC-BRK-008, REQ-RISK-073
    function test_TEST_268_restoredSettingStaysClosedUntilReset() public {
        _debt(1.5e18, 1000);
        rSpoke.setImplSlot(bytes32(uint256(uint160(makeAddr("upgraded")))));
        riskModule.pokeConfig(address(spoke));
        spoke.setImplementation(address(spokeImpl));
        uint256[] memory ids = new uint256[](1);
        ids[0] = mid;
        // The drift check itself passes again; the latched freeze still stops new debt, never the top-up.
        riskModule.checkAaveConfig(address(spoke), ids);
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, mid, BreakerReasons.CONFIG_DRIFT)
        );
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, mid, BreakerReasons.CONFIG_DRIFT)
        );
        riskModule.preWithdrawCheck(address(proxy));
        riskModule.checkPledge(wallet, address(proxy), mid, V3, bytes32(uint256(1)), UNITS, _counters(), false);
        AccountGateStatus memory s = riskModule.getAccountGateStatus(address(proxy));
        assertEq(uint8(s.driftReason), uint8(DriftReason.None));
        assertEq(s.markets[0].breakerReasons, BreakerReasons.CONFIG_DRIFT);
        assertFalse(s.borrowAllowed);
        vm.prank(emergencyGuardian);
        registry.resetMarketBreaker(mid);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        riskModule.preWithdrawCheck(address(proxy));
    }
}

