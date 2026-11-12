// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {AccountGateStatus} from "../../src/types/AccountGateStatus.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {PledgePreview} from "../../src/types/PledgePreview.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModuleHealthUnitTest
/// @notice The rescue-excluded health check, the remaining-record minimum, the debt value, the restore amount and the
/// non-reverting previews.
contract RiskModuleHealthUnitTest is RiskModuleFixture {
    function setUp() public {
        _deployRiskWorld();
    }

    /// @dev Rescue units worth $1,000 at $2.00 on an account key with CF 3,120.
    function _rescueAccount(
        uint256 hf
    ) internal {
        _debt(hf, 10_000);
        coll.setRescue(address(proxy), 500e18);
        IAaveV4Spoke.DynamicReserveConfig memory d;
        (d.collateralFactor, d.maxLiquidationBonus) = (3120, 10_500);
        rSpoke.setDynamicAt(VT_RESERVE, 9, d);
        rSpoke.setUserKey(address(proxy), VT_RESERVE, 9);
    }

    // TEST-236 verifies: REQ-RISK-068, REQ-ADAPTER-026, SPEC-CF-005, INV-082, SPEC-CF-003
    // Sources: 2.7 SPEC-CF-005 example and 5.1 TEST-236 (HF 1.2000, debt $10,000, rescue $1,000 at CF 0.312)
    function test_TEST_236_rescueUnitsExcluded() public {
        _rescueAccount(1.2e18);
        assertEq(riskModule.postHealthCheck(address(proxy), 0), 1.1688e18);
        // With the caller's minimum at 1.10, a borrow ending at HF 1.12 reverts at hfEx 1.0888.
        _rescueAccount(1.12e18);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, 1.0888e18, 1.1e18));
        riskModule.postHealthCheck(address(proxy), 1.1e18);
        // With the market's hard floor at 1.10 the same.
        store.setHardFloor(mid, 1.1e18);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, 1.0888e18, 1.1e18));
        riskModule.postHealthCheck(address(proxy), 0);
        // With both off, HF 1.02 reverts at hfEx 0.9888 against Aave's 1.00.
        store.setHardFloor(mid, 0);
        _rescueAccount(1.02e18);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, 0.9888e18, 1e18));
        riskModule.postHealthCheck(address(proxy), 0);
    }

    // TEST-236 verifies: REQ-RISK-059, REQ-ADAPTER-027, INV-025, SPEC-CF-003
    function test_TEST_236_noRescueUnitsIsAaveHealthFactor() public {
        _debt(1.05e18, 10_000);
        assertEq(riskModule.postHealthCheck(address(proxy), 1.05e18), 1.05e18);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, 1.05e18, 1.0500001e18));
        riskModule.postHealthCheck(address(proxy), 1.0500001e18);
        // No opening floor above Aave's 1.00 (Q-398).
        _debt(1e18, 10_000);
        assertEq(riskModule.postHealthCheck(address(proxy), 0), 1e18);
        assertEq(riskModule.rescueHealthFactor(), 1.1e18);
    }

    // TEST-237 verifies: REQ-RISK-070, REQ-RISK-075, INV-088
    // Sources: 2.7 REQ-RISK-070 example (price8 199,990,000, minPledgeUsd $10), here with d = 18
    function test_TEST_237_remainingRecordMinimum() public {
        oracle.setPrices(199_990_000, 199_990_000);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.RecordBelowMinPledge.selector, 799_960_000, 1e9));
        riskModule.checkRemainingRecord(mid, 4e18);
        riskModule.checkRemainingRecord(mid, 5.001e18);
    }

    // TEST-272 verifies: SPEC-CAP-009, REQ-RISK-077
    // Sources: 2.7 SPEC-CAP-009 example ($28,080 and $50)
    function test_TEST_272_debtValue() public {
        rSpoke.setAccount(address(proxy), 1.5e18, 2.808e57, 1);
        assertEq(riskModule.debtValueUsd(address(proxy)), 2_808_000_000_000);
        rSpoke.setAccount(address(proxy), 1.5e18, 5e54, 1);
        assertEq(riskModule.debtValueUsd(address(proxy)), 5_000_000_000);
    }

    // TEST-013 verifies: SPEC-CAP-003, REQ-RISK-026
    // Sources: 2.7 SPEC-CAP-003 example (D = 1e57, hf 1.02, CF 3,000; Drifting accepted 198,950,000, served 154,800,000)
    function test_TEST_013_restoreAmountUsesServedPrice() public {
        _debt(1.02e18, 10_000);
        assertEq(riskModule.usdToRestore(address(proxy)), 266_666_666_667);
        // While Drifting the restore amount on the booking basis divides by the served price.
        oracle.setPrices(198_950_000, 154_800_000);
        oracle.setState(PriceState.Drifting, 1 << 2, false);
        PledgeCounters memory k = _counters();
        k.regularUsed = 1_000_000e8; // no regular room: the whole charge goes to the slice
        // ceil(266,666,666,667 * 198,950,000 / 154,800,000) = 342,721,791,560.
        vm.expectRevert(IRiskModuleErrors.SliceNotAvailable.selector);
        _pledge(1723e18, k, false); // charge 342,790,850,000 > restoreBooked
        assertEq(_pledge(1722e18, k, false).sliceUsd, 342_591_900_000);
        // No debt, or at or above 1.10: nothing to restore.
        _debt(1.1e18, 10_000);
        assertEq(riskModule.usdToRestore(address(proxy)), 0);
    }

    // TEST-034 verifies: REQ-RISK-031, REQ-RISK-010, REQ-RISK-057, REQ-RISK-008, REQ-RISK-012, REQ-RISK-027
    function test_TEST_034_previewPledge() public {
        bytes32 key = bytes32(uint256(7));
        rVault.setPosition(key, wallet, 10_000e18);
        PledgeCounters memory k = _counters();
        coll.setCounters(k);
        PledgePreview memory p = riskModule.previewPledge(wallet, mid, key);
        assertTrue(p.eligible);
        assertEq(p.usdCharge, 20_000e8);
        assertEq(p.marketRoomUsd, 1_000_000e8);
        assertEq(p.sliceRoomUsd, 100_000e8);
        assertEq(p.tokenRoomUsd.length, 2);
        assertEq(p.recordRoom, 16);
        assertEq(p.poolShareRoomUnits, type(uint256).max);
        // Not the owner.
        p = riskModule.previewPledge(makeAddr("stranger"), mid, key);
        assertFalse(p.eligible);
        assertEq(p.reason, IRiskModuleErrors.NotPositionOwner.selector);
        // Below the minimum, reported without reverting.
        rVault.setPosition(key, wallet, 4.99e18);
        p = riskModule.previewPledge(wallet, mid, key);
        assertEq(p.reason, IRiskModuleErrors.BelowMinPledge.selector);
        // A 17th record.
        rVault.setPosition(key, wallet, 10_000e18);
        coll.setOpenRecords(address(proxy), 16);
        p = riskModule.previewPledge(wallet, mid, key);
        assertEq(p.reason, IRiskModuleErrors.TooManyRecords.selector);
        assertEq(p.recordRoom, 0);
        // The integration's shape error passes through.
        coll.setOpenRecords(address(proxy), 0);
        rVault.setValidateError(bytes4(keccak256("ShapeMismatch()")));
        p = riskModule.previewPledge(wallet, mid, key);
        assertEq(p.reason, bytes4(keccak256("ShapeMismatch()")));
    }

    // TEST-028 verifies: REQ-ADAPTER-038, REQ-RISK-060
    function test_TEST_028_accountGateStatus() public {
        _debt(1.5e18, 1000);
        AccountGateStatus memory s = riskModule.getAccountGateStatus(address(proxy));
        assertTrue(s.spokeApproved);
        assertTrue(s.borrowAllowed);
        assertTrue(s.withdrawWithDebtAllowed);
        assertEq(s.healthFactor, 1.5e18);
        assertEq(s.healthFactorExcludingRescue, 1.5e18);
        assertEq(s.markets.length, 1);
        assertEq(s.markets[0].marketId, mid);
        assertEq(s.unknownCollateralReserveId, type(uint256).max);
        assertFalse(s.noApprovedKeeper);
        // A frozen reserve with shares blocks borrowing only; the status does not poke.
        uint256 pokes = oracle.pokes();
        IAaveV4Spoke.ReserveConfig memory v;
        v.frozen = true;
        rSpoke.setConfig(VT_RESERVE, v);
        s = riskModule.getAccountGateStatus(address(proxy));
        assertFalse(s.borrowAllowed);
        assertTrue(s.withdrawWithDebtAllowed);
        assertTrue(s.markets[0].aaveReserveFrozen);
        assertEq(oracle.pokes(), pokes);
        // The pause state of the market's Hub is reported.
        vm.prank(emergencyGuardian);
        registry.freeze(address(hub));
        s = riskModule.getAccountGateStatus(address(proxy));
        assertEq(uint8(s.pauseState), uint8(PauseState.Frozen));
        // A broken account never reverts the view.
        s = riskModule.getAccountGateStatus(makeAddr("notAProxy"));
        assertFalse(s.borrowAllowed);
    }

    // TEST-028 verifies: REQ-RISK-031
    function test_TEST_028_previewNeverReverts() public view {
        PledgePreview memory p = riskModule.previewPledge(wallet, 999, bytes32(0));
        assertFalse(p.eligible);
    }
}
