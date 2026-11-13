// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationAdapter} from "../../src/custody/collateralization/ICollateralizationAdapter.sol";
import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {ILPVaultErrors} from "../../src/custody/lp-vault/ILPVaultErrors.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {IAaveAdapterEvents} from "../../src/policy/aave-adapter/IAaveAdapterEvents.sol";
import {IRiskModuleChecks} from "../../src/policy/risk-module/IRiskModuleChecks.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {PositionRef} from "../../src/types/PositionRef.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";

/// @title AaveAdapterCollateralUnitTest
/// @notice `removeLiquidity` and `recredit` on the real Aave V4 Spoke and Collateralization: partial removal keeps the
/// position in custody and pays the n token amounts to the depositor of record, with the with-debt gates only when debt
/// remains; re-credit mints and supplies exactly the units Collateralization adds, under the pledge's pause and rescue
/// rules; both keep the backing gap.
/// forge-config: default.isolate = false
contract AaveAdapterCollateralUnitTest is AaveAdapterFixture {
    bytes32 internal k1;
    address internal p;

    function setUp() public override {
        super.setUp();
        (k1, p) = _pledgeAs(alice, MARKET_ID, UNITS);
    }

    function _remove(
        uint128 units,
        uint256 minHf
    ) internal returns (uint256[] memory amounts) {
        uint256 d = _deadline();
        vm.prank(alice);
        amounts = adapterC.removeLiquidity(MARKET_ID, _ref(k1), units, _mins(), d, minHf);
    }

    function _expectRemoveRevert(
        bytes memory err,
        uint128 units
    ) internal {
        uint256 d = _deadline();
        uint256[] memory mins = _mins();
        vm.expectRevert(err);
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(k1), units, mins, d, 0);
    }

    // ─── Partial removal ───

    // TEST-237 verifies: REQ-ADAPTER-078, REQ-ADAPTER-069, SPEC-PROXY-008, INV-088, WDR-031
    // Sources: 5.1 TEST-237, 2.6 REQ-ADAPTER-078 example
    /// @notice A debt-free removal of 2,000 vault tokens burns exactly those units from the proxy, keeps the position
    /// in custody, pays the unwound tokens to the depositor of record, keeps the backing gap and emits
    /// `CollateralReduced(…, false, type(uint256).max)` with no RiskModule call.
    function test_TEST_237_debtFreeRemoval() public {
        uint128 units = 2_000_000_000;
        uint256[] memory expected = new uint256[](2);
        expected[0] = uint256(units) * 800_000 / 1e6;
        expected[1] = uint256(units) * 1_250_000 / 1e6;
        vm.expectCall(vt, abi.encodeCall(IVaultToken.burn, (p, units)), 1);
        vm.expectCall(address(risk), abi.encodeWithSelector(IRiskModuleChecks.preWithdrawCheck.selector), 0);
        vm.expectCall(address(risk), abi.encodeWithSelector(IRiskModuleChecks.checkRemainingRecord.selector), 0);
        vm.expectEmit(adapter);
        emit IAaveAdapterEvents.CollateralReduced(alice, MARKET_ID, vt, k1, units, expected, false, type(uint256).max);
        uint256[] memory amounts = _remove(units, 0);
        assertEq(amounts[0], expected[0], "USDC");
        assertEq(amounts[1], expected[1], "USDT");
        assertEq(usdc.balanceOf(alice), expected[0], "paid USDC");
        assertEq(usdt.balanceOf(alice), expected[1], "paid USDT");
        assertEq(lpVault.depositorOf(k1), alice, "still in custody");
        assertEq(_sharesOf(p, vtReserveId), UNITS - units, "shares");
        assertEq(token.totalSupply(), UNITS - units, "supply");
        assertEq(coll.getTotalCredited(vt), UNITS - units, "credited");
        (bool enabled,) = adapterCSpokeStatus(p);
        assertTrue(enabled, "collateral stays enabled");
    }

    function adapterCSpokeStatus(
        address proxy
    ) internal view returns (bool enabled, bool borrowing) {
        (enabled, borrowing) = IAaveV4SpokeStatus(aave.cdpSpoke).getUserReserveStatus(vtReserveId, proxy);
    }

    // TEST-237 verifies: REQ-ADAPTER-078, REQ-ADAPTER-086, REQ-ADAPTER-047, REQ-ACCESS-068
    /// @notice A debt-free removal reads no MarketRegistry, pause, freeze or RiskModule: it passes with all broken.
    function test_TEST_237_debtFreeRemovalIgnoresStops() public {
        registry.setFrozen(alice, true);
        _pause(PauseState.Paused, PauseReason.MintPathSuspect);
        registry.setBroken(true);
        risk.setBroken(true);
        vm.expectCall(address(registry), "", 0);
        vm.expectCall(address(risk), "", 0);
        _remove(1_000_000_000, 0);
        assertEq(_sharesOf(p, vtReserveId), UNITS - 1_000_000_000, "removed");
    }

    // TEST-237 verifies: REQ-ADAPTER-078, REQ-ADAPTER-046, REQ-ADAPTER-073, REQ-ADAPTER-082, REQ-ADAPTER-087, REQ-RISK-070, SPEC-PROXY-001
    /// @notice With debt: Paused (either reason) refuses, a frozen caller is refused, and otherwise
    /// `preWithdrawCheck`, `checkRemainingRecord(market, remaining)` and `postHealthCheck` run.
    function test_TEST_237_withDebtGates() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 1000e18);
        _pause(PauseState.Paused, PauseReason.General);
        _expectRemoveRevert(abi.encodeWithSelector(IAaveAdapterErrors.ApplicationPaused.selector), 1_000_000_000);
        _pause(PauseState.Paused, PauseReason.MintPathSuspect);
        _expectRemoveRevert(abi.encodeWithSelector(IAaveAdapterErrors.ApplicationPaused.selector), 1_000_000_000);
        _pause(PauseState.Frozen, PauseReason.None);
        registry.setFrozen(alice, true);
        _expectRemoveRevert(abi.encodeWithSelector(IAaveAdapterErrors.AddressIsFrozen.selector, alice), 1_000_000_000);
        registry.setFrozen(alice, false);
        vm.expectCall(address(risk), abi.encodeCall(IRiskModuleChecks.preWithdrawCheck, (p)), 1);
        vm.expectCall(
            address(risk), abi.encodeCall(IRiskModuleChecks.checkRemainingRecord, (MARKET_ID, UNITS - 1_000_000_000)), 1
        );
        vm.expectCall(address(risk), abi.encodeCall(IRiskModuleChecks.postHealthCheck, (p, 1.1e18)), 1);
        _remove(1_000_000_000, 1.1e18);
    }

    // TEST-237 verifies: REQ-ADAPTER-078, REQ-ADAPTER-089, REQ-RISK-070
    /// @notice With debt a remaining record below the minimum reverts the RiskModule's `RecordBelowMinPledge`, and a
    /// health factor below the caller's minimum its `HealthFactorTooLow`.
    function test_TEST_237_withDebtRemainingAndHealth() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 2000e18);
        risk.setMinRemaining(5_000_000_000);
        _expectRemoveRevert(
            abi.encodeWithSelector(IRiskModuleErrors.RecordBelowMinPledge.selector, 4_000_000_000, 5_000_000_000),
            6_000_000_000
        );
        risk.setMinRemaining(0);
        // Removing 4,000 tokens leaves $12,000 × 0.80 = $9,600 against 2,000: hf 4.8.
        uint256 d = _deadline();
        uint256[] memory mins = _mins();
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, 4.8e18, 5e18));
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(k1), 4_000_000_000, mins, d, 5e18);
        uint256 hf = 4.8e18;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 3_200_000_000;
        amounts[1] = 5_000_000_000;
        vm.expectEmit(adapter);
        emit IAaveAdapterEvents.CollateralReduced(alice, MARKET_ID, vt, k1, 4_000_000_000, amounts, true, hf);
        _remove(4_000_000_000, 4.8e18);
    }

    // TEST-237 verifies: REQ-ADAPTER-078, REQ-ADAPTER-089
    /// @notice Removing all of a record's credited units (or more) is refused by Collateralization with
    /// `PartialRemovalTooLarge`; a whole record leaves through `withdraw`.
    function test_TEST_237_wholeRecordRefused() public {
        _expectRemoveRevert(
            abi.encodeWithSelector(ICollateralizationErrors.PartialRemovalTooLarge.selector, UNITS, UNITS), UNITS
        );
    }

    // TEST-237 verifies: REQ-ADAPTER-078, REQ-ADAPTER-089
    /// @notice The per-token minimums are the depositor's: a wrong length fails Collateralization's
    /// `LengthMismatch(expected, actual)` and a minimum above the unwound amount the LPVault's `BelowMinimum`.
    function test_TEST_237_minimums() public {
        uint256 d = _deadline();
        uint256[] memory three = new uint256[](3);
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.LengthMismatch.selector, 2, 3));
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(k1), 1_000_000_000, three, d, 0);
        uint256[] memory high = new uint256[](2);
        high[0] = 800_000_001;
        vm.expectRevert(abi.encodeWithSelector(ILPVaultErrors.BelowMinimum.selector, 0, 800_000_000, 800_000_001));
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(k1), 1_000_000_000, high, d, 0);
    }

    // TEST-237 verifies: REQ-ADAPTER-078, REQ-PROXY-057, REQ-PROXY-058, REQ-PROXY-060, REQ-PROXY-062
    /// @notice Bounds in order: deadline, zero units, proxy, integration.
    function test_TEST_237_checkOrder() public {
        uint256 past = block.timestamp - 1;
        uint256[] memory mins = _mins();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.DeadlineExpired.selector, past));
        vm.prank(bob);
        adapterC.removeLiquidity(MARKET_ID, PositionRef(9, k1), 0, mins, past, 0);
        uint256 d = _deadline();
        vm.expectRevert(IAaveAdapterErrors.ZeroAmount.selector);
        vm.prank(bob);
        adapterC.removeLiquidity(MARKET_ID, PositionRef(9, k1), 0, mins, d, 0);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.NoProxy.selector, bob, MARKET_ID));
        vm.prank(bob);
        adapterC.removeLiquidity(MARKET_ID, PositionRef(9, k1), 1, mins, d, 0);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.IntegrationMismatch.selector, MARKET_ID, 9));
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, PositionRef(9, k1), 1, mins, d, 0);
    }

    // TEST-241 verifies: REQ-ADAPTER-069, REQ-ADAPTER-075
    /// @notice A Collateralization that debits nothing for a removal leaves the burn unmatched: `BackingMismatch`.
    function test_TEST_241_removalWithoutDebitReverts() public {
        uint256[] memory amounts = new uint256[](2);
        vm.mockCall(
            address(coll),
            abi.encodeWithSelector(ICollateralizationAdapter.releasePartial.selector),
            abi.encode(uint128(UNITS - 1), amounts)
        );
        _expectRemoveRevert(abi.encodeWithSelector(IAaveAdapterErrors.BackingMismatch.selector, UNITS - 1, UNITS, 0), 1);
    }

    // ─── Re-credit ───

    // TEST-238 verifies: REQ-ADAPTER-079, REQ-ADAPTER-069, REQ-COLL-037, INV-088, ATTACK-143
    // Sources: 5.1 TEST-238, 2.6 REQ-ADAPTER-079 example
    /// @notice After the depositor adds 2,500 vault tokens of liquidity to the custodied position, `recredit` mints and
    /// supplies exactly the added units and emits `CollateralRecredited` with the record and its rescue units.
    function test_TEST_238_recredit() public {
        lpVault.addUnits(k1, 2_500_000_000);
        uint256 recordId = coll.recordIdOf(INTEGRATION, k1);
        vm.expectCall(vt, abi.encodeCall(IVaultToken.mint, (p, 2_500_000_000)), 1);
        vm.expectEmit(adapter);
        emit IAaveAdapterEvents.CollateralSupplied(p, MARKET_ID, 2_500_000_000, 2_500_000_000);
        vm.expectEmit(adapter);
        emit IAaveAdapterEvents.CollateralRecredited(alice, MARKET_ID, vt, recordId, k1, 2_500_000_000, 0);
        vm.prank(alice);
        uint128 added = adapterC.recredit(MARKET_ID, _ref(k1), "", _deadline());
        assertEq(added, 2_500_000_000, "added");
        assertEq(_sharesOf(p, vtReserveId), UNITS + 2_500_000_000, "supplied");
        assertEq(coll.getTotalCredited(vt), UNITS + 2_500_000_000, "credited");
        assertEq(token.totalSupply(), UNITS + 2_500_000_000, "supply");
    }

    // TEST-238 verifies: REQ-ADAPTER-079, REQ-ADAPTER-090
    /// @notice Nothing added reverts `NothingToRecredit`; a wallet that is not the depositor reverts `NotDepositor`.
    function test_TEST_238_recreditRefusals() public {
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.NothingToRecredit.selector, k1));
        vm.prank(alice);
        adapterC.recredit(MARKET_ID, _ref(k1), "", d);
        lpVault.addUnits(k1, 1_000_000);
        _pledgeAs(bob, MARKET_ID, UNITS);
        vm.expectRevert();
        vm.prank(bob);
        adapterC.recredit(MARKET_ID, _ref(k1), "", d);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.NoProxy.selector, carol, MARKET_ID));
        vm.prank(carol);
        adapterC.recredit(MARKET_ID, _ref(k1), "", d);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.IntegrationMismatch.selector, MARKET_ID, 9));
        vm.prank(alice);
        adapterC.recredit(MARKET_ID, PositionRef(9, k1), "", d);
        uint256 past = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.DeadlineExpired.selector, past));
        vm.prank(alice);
        adapterC.recredit(MARKET_ID, _ref(k1), "", past);
    }

    // TEST-235 verifies: REQ-ADAPTER-079, REQ-ADAPTER-083, REQ-ADAPTER-045, REQ-ADAPTER-046, REQ-ADAPTER-072, REQ-ADAPTER-073, REQ-ACCESS-079
    /// @notice A re-credit follows the pledge's pause rules: `MintPathSuspect` refuses, Frozen refuses a debt-free
    /// account and admits an indebted one without rescue, `Paused(General)` and a frozen caller ask for a rescue.
    function test_TEST_235_recreditPauseRules() public {
        lpVault.addUnits(k1, 1_000_000_000);
        uint256 d = _deadline();
        _pause(PauseState.Paused, PauseReason.MintPathSuspect);
        vm.expectRevert(IAaveAdapterErrors.ApplicationPaused.selector);
        vm.prank(alice);
        adapterC.recredit(MARKET_ID, _ref(k1), "", d);
        _pause(PauseState.Frozen, PauseReason.None);
        vm.expectRevert(IAaveAdapterErrors.ApplicationFrozen.selector);
        vm.prank(alice);
        adapterC.recredit(MARKET_ID, _ref(k1), "", d);
        _pause(PauseState.None, PauseReason.None);
        _borrowAs(alice, MARKET_ID, debtReserveId, 100e18);
        _pause(PauseState.Paused, PauseReason.General);
        vm.expectCall(
            address(coll), abi.encodeCall(ICollateralizationAdapter.recredit, (alice, p, vt, k1, "", true)), 1
        );
        vm.prank(alice);
        adapterC.recredit(MARKET_ID, _ref(k1), "", d);
        lpVault.addUnits(k1, 1_000_000_000);
        _pause(PauseState.Frozen, PauseReason.None);
        vm.expectCall(
            address(coll), abi.encodeCall(ICollateralizationAdapter.recredit, (alice, p, vt, k1, "", false)), 1
        );
        vm.prank(alice);
        adapterC.recredit(MARKET_ID, _ref(k1), "", d);
    }

    // TEST-229 verifies: REQ-ADAPTER-082, REQ-ADAPTER-083
    /// @notice A frozen depositor's re-credit is a rescue top-up.
    function test_TEST_229_frozenRecreditIsRescue() public {
        lpVault.addUnits(k1, 1_000_000_000);
        registry.setFrozen(alice, true);
        vm.expectCall(
            address(coll), abi.encodeCall(ICollateralizationAdapter.recredit, (alice, p, vt, k1, "", true)), 1
        );
        vm.prank(alice);
        adapterC.recredit(MARKET_ID, _ref(k1), "", _deadline());
    }

    // TEST-241 verifies: REQ-ADAPTER-005, REQ-ADAPTER-069, REQ-ADAPTER-075
    /// @notice A Collateralization answer of 0 added never reaches a mint (`ZeroAmount`); one that credits nothing it
    /// reports breaks the backing gap (`BackingMismatch`).
    function test_TEST_241_recreditCreditChecks() public {
        uint256 d = _deadline();
        vm.mockCall(
            address(coll),
            abi.encodeWithSelector(ICollateralizationAdapter.recredit.selector),
            abi.encode(uint128(0), uint128(0))
        );
        vm.expectRevert(IAaveAdapterErrors.ZeroAmount.selector);
        vm.prank(alice);
        adapterC.recredit(MARKET_ID, _ref(k1), "", d);
        vm.mockCall(
            address(coll),
            abi.encodeWithSelector(ICollateralizationAdapter.recredit.selector),
            abi.encode(uint128(5), uint128(0))
        );
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.BackingMismatch.selector, UNITS + 5, UNITS, 0));
        vm.prank(alice);
        adapterC.recredit(MARKET_ID, _ref(k1), "", d);
    }
}

interface IAaveV4SpokeStatus {
    function getUserReserveStatus(
        uint256 reserveId,
        address user
    ) external view returns (bool, bool);
}
