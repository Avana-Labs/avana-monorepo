// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationAdapter} from "../../src/custody/collateralization/ICollateralizationAdapter.sol";
import {ICollateralizationDebtMark} from "../../src/custody/collateralization/ICollateralizationDebtMark.sol";
import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {ICollateralizationEvents} from "../../src/custody/collateralization/ICollateralizationEvents.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILock} from "../../src/lock/lock/ILock.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {IAaveAdapterEvents} from "../../src/policy/aave-adapter/IAaveAdapterEvents.sol";
import {IRiskModuleChecks} from "../../src/policy/risk-module/IRiskModuleChecks.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {PositionRef} from "../../src/types/PositionRef.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title AaveAdapterWithdrawUnitTest
/// @notice `withdraw`, `repayAllAndWithdraw`, `collectFees`, `releaseZeroCredit` and `refreshDebtMark` on the real
/// Aave V4 Spoke and Collateralization: the debt-free test from Aave's borrow count, the order withdraw → burn → release
/// → cleanup or health check → backing check, the with-debt gates, the reconciliation of an unsettled seizure, and the
/// exits that read no MarketRegistry, pause, freeze, breaker or RiskModule.
/// forge-config: default.isolate = false
contract AaveAdapterWithdrawUnitTest is AaveAdapterFixture {
    bytes32 internal k1;
    bytes32 internal k2;
    address internal p;

    function setUp() public override {
        super.setUp();
        (k1, p) = _pledgeAs(alice, MARKET_ID, UNITS);
        (k2,) = _pledgeAs(alice, MARKET_ID, UNITS / 2);
    }

    function _withdraw(
        bytes32 key,
        uint256 units,
        uint256 minHf
    ) internal {
        uint256 d = _deadline();
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(key), units, d, minHf);
    }

    function _expectWithdrawRevert(
        bytes memory err,
        bytes32 key,
        uint256 units
    ) internal {
        uint256 d = _deadline();
        vm.expectRevert(err);
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(key), units, d, 0);
    }

    function _breakEverything() internal {
        registry.setFrozen(alice, true);
        _pause(PauseState.Paused, PauseReason.MintPathSuspect);
        registry.setBroken(true);
        risk.setBroken(true);
        pstore.setSequencer(address(0xdead), 0);
    }

    // ─── Debt-free withdrawal ───

    // TEST-018 verifies: REQ-PROXY-033, REQ-PROXY-034, REQ-PROXY-035, REQ-PROXY-037, REQ-PROXY-038, REQ-PROXY-039, REQ-ADAPTER-009, INV-045, Q-260
    // Sources: 5.1 TEST-018, FLOW-004
    /// @notice A debt-free withdrawal burns exactly the record's units from the proxy, debits the record, returns the
    /// position to its depositor and emits `CollateralWithdrawn(…, false, type(uint256).max)`.
    function test_TEST_018_debtFreeWithdraw() public {
        vm.expectCall(vt, abi.encodeCall(IVaultToken.burn, (p, UNITS)), 1);
        vm.expectCall(address(coll), abi.encodeCall(ICollateralizationAdapter.release, (p, vt, k1, UNITS)), 1);
        vm.expectCall(address(risk), abi.encodeWithSelector(IRiskModuleChecks.preWithdrawCheck.selector), 0);
        vm.expectCall(address(risk), abi.encodeWithSelector(IRiskModuleChecks.postHealthCheck.selector), 0);
        vm.expectEmit(adapter);
        emit IAaveAdapterEvents.CollateralWithdrawn(alice, MARKET_ID, vt, k1, UNITS, false, type(uint256).max);
        _withdraw(k1, UNITS, 0);
        assertEq(lpVault.ownerOf(k1), alice, "position returned");
        assertEq(_sharesOf(p, vtReserveId), UNITS / 2, "one record left");
        assertEq(token.totalSupply(), UNITS / 2, "burned");
        assertEq(token.balanceOf(p), 0, "proxy holds no units");
        assertEq(coll.getTotalCredited(vt), UNITS / 2, "debited");
    }

    // TEST-209 verifies: REQ-PROXY-038, REQ-PROXY-037, REQ-ADAPTER-069, INV-013
    // Sources: 5.1 TEST-209
    /// @notice The order of a withdrawal, read from the ordered event log: the Spoke's `Withdraw` paying the proxy,
    /// the burn, Collateralization's `CollateralReleased`, then the cleanup's collateral disable, then
    /// `CollateralWithdrawn`.
    function test_TEST_209_withdrawOrder() public {
        _withdraw(k2, UNITS / 2, 0);
        vm.recordLogs();
        _withdraw(k1, UNITS, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 hubToProxy = type(uint256).max;
        uint256 burn = type(uint256).max;
        uint256 released = type(uint256).max;
        uint256 disabled = type(uint256).max;
        uint256 withdrawn = type(uint256).max;
        bytes32 transferSig = IERC20.Transfer.selector;
        for (uint256 i = 0; i < logs.length; ++i) {
            bytes32 t0 = logs[i].topics[0];
            if (logs[i].emitter == vt && t0 == transferSig) {
                address from = address(uint160(uint256(logs[i].topics[1])));
                address to = address(uint160(uint256(logs[i].topics[2])));
                if (from == aave.hub && to == p) hubToProxy = i;
                if (from == p && to == address(0)) burn = i;
            }
            if (logs[i].emitter == address(coll) && t0 == ICollateralizationEvents.CollateralReleased.selector) {
                released = i;
            }
            if (logs[i].emitter == adapter && t0 == IAaveAdapterEvents.CollateralDisabled.selector) disabled = i;
            if (logs[i].emitter == adapter && t0 == IAaveAdapterEvents.CollateralWithdrawn.selector) withdrawn = i;
        }
        assertLt(hubToProxy, burn, "withdraw before burn");
        assertLt(burn, released, "burn before release");
        assertLt(released, disabled, "release before cleanup");
        assertLt(disabled, withdrawn, "cleanup before the event");
        assertTrue(withdrawn != type(uint256).max, "event seen");
    }

    // TEST-018 verifies: REQ-PROXY-046, REQ-PROXY-039
    /// @notice Close-out of the last position disables the reserve as collateral (`CollateralDisabled`), leaves the
    /// proxy, the Adapter and Collateralization with no units, and a later pledge reuses the same proxy.
    function test_TEST_018_closeOutCleansUp() public {
        _withdraw(k2, UNITS / 2, 0);
        vm.expectEmit(adapter);
        emit IAaveAdapterEvents.CollateralDisabled(p, vtReserveId);
        _withdraw(k1, UNITS, 0);
        (bool enabled,) = IAaveV4Spoke(aave.cdpSpoke).getUserReserveStatus(vtReserveId, p);
        assertFalse(enabled, "disabled");
        assertEq(token.balanceOf(p) + token.balanceOf(adapter) + token.balanceOf(address(coll)), 0, "no units left");
        assertEq(coll.getOpenRecordCount(p, vt), 0, "no record");
        (, address again) = _pledgeAs(alice, MARKET_ID, UNITS);
        assertEq(again, p, "same proxy");
        (enabled,) = IAaveV4Spoke(aave.cdpSpoke).getUserReserveStatus(vtReserveId, p);
        assertTrue(enabled, "re-enabled on pledge");
    }

    // TEST-018 verifies: REQ-PROXY-046
    /// @notice A withdrawal that leaves units on the account keeps the reserve enabled (no cleanup event).
    function test_TEST_018_noCleanupWhileSupplied() public {
        vm.recordLogs();
        _withdraw(k1, UNITS, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IAaveAdapterEvents.CollateralDisabled.selector, "no cleanup");
        }
        (bool enabled,) = IAaveV4Spoke(aave.cdpSpoke).getUserReserveStatus(vtReserveId, p);
        assertTrue(enabled, "still enabled");
    }

    // TEST-229 verifies: REQ-PROXY-035, REQ-ADAPTER-047, REQ-ADAPTER-082, REQ-ADAPTER-086, REQ-ACCESS-068, INV-045, INV-067, ATTACK-035, ATTACK-043
    // Sources: real-Aave list (exits with a reverting registry or RiskModule)
    /// @notice A debt-free withdrawal succeeds for a frozen wallet under `Paused(MintPathSuspect)` with a
    /// MarketRegistry, a RiskModule and a sequencer read that all revert: it reads none of them.
    function test_TEST_229_debtFreeWithdrawIgnoresEveryStop() public {
        _breakEverything();
        vm.expectCall(address(registry), "", 0);
        vm.expectCall(address(risk), "", 0);
        vm.expectCall(address(pstore), "", 0);
        _withdraw(k1, UNITS, 0);
        _withdraw(k2, UNITS / 2, 0);
        assertEq(lpVault.ownerOf(k1), alice, "k1 back");
        assertEq(lpVault.ownerOf(k2), alice, "k2 back");
    }

    // ─── With debt ───

    // TEST-019 verifies: REQ-PROXY-036, REQ-ADAPTER-046, REQ-ADAPTER-053, REQ-ADAPTER-073, REQ-ACCESS-069, REQ-ACCESS-073, REQ-ACCESS-074, INV-023
    // Sources: 5.1 TEST-019
    /// @notice A withdrawal that leaves debt reverts `ApplicationPaused` under Paused with either reason and passes
    /// under Frozen.
    function test_TEST_019_withDebtPauseGate() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 1000e18);
        _pause(PauseState.Paused, PauseReason.General);
        _expectWithdrawRevert(abi.encodeWithSelector(IAaveAdapterErrors.ApplicationPaused.selector), k2, UNITS / 2);
        _pause(PauseState.Paused, PauseReason.MintPathSuspect);
        _expectWithdrawRevert(abi.encodeWithSelector(IAaveAdapterErrors.ApplicationPaused.selector), k2, UNITS / 2);
        _pause(PauseState.Frozen, PauseReason.None);
        assertEq(risk.preWithdrawCalls(), 0, "refused before the RiskModule");
        _withdraw(k2, UNITS / 2, 0);
        assertEq(lpVault.ownerOf(k2), alice, "withdrawn under Frozen");
    }

    // TEST-019 verifies: REQ-PROXY-036, REQ-PROXY-022, SPEC-PROXY-001, REQ-ADAPTER-087, INV-024, INV-025
    /// @notice With debt: a frozen caller reverts `AddressIsFrozen`; otherwise `preWithdrawCheck` runs before the Spoke
    /// call and `postHealthCheck(proxy, minHealthFactor)` after the release, and the event carries its health factor.
    function test_TEST_019_withDebtGatesAndHealthCheck() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 1000e18);
        registry.setFrozen(alice, true);
        _expectWithdrawRevert(abi.encodeWithSelector(IAaveAdapterErrors.AddressIsFrozen.selector, alice), k2, UNITS / 2);
        registry.setFrozen(alice, false);
        vm.expectCall(address(risk), abi.encodeCall(IRiskModuleChecks.preWithdrawCheck, (p)), 1);
        vm.expectCall(address(risk), abi.encodeCall(IRiskModuleChecks.postHealthCheck, (p, 1.2e18)), 1);
        uint256 hfAfter = uint256(16_000e18) * 1e18 / 1000e18; // the remaining $20,000 record at CF 80%
        vm.expectEmit(adapter);
        emit IAaveAdapterEvents.CollateralWithdrawn(alice, MARKET_ID, vt, k2, UNITS / 2, true, hfAfter);
        _withdraw(k2, UNITS / 2, 1.2e18);
        assertEq(risk.preWithdrawCalls(), 1, "pre-check");
    }

    // TEST-019 verifies: REQ-PROXY-036, REQ-PROXY-067, SPEC-PROXY-001
    /// @notice A with-debt withdrawal ending below the caller's minimum, or below a market's hard floor, reverts with
    /// the RiskModule's `HealthFactorTooLow`, undoing the Spoke withdrawal, the burn and the release.
    function test_TEST_019_healthFloorAfterWithdraw() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 10_000e18);
        // After withdrawing k2: $16,000 × 1e18 / 10,000 = 1.6.
        uint256 hf = 1.6e18;
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, hf, 2e18));
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k2), UNITS / 2, d, 2e18);
        risk.setHardFloor(1.7e18);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, hf, 1.7e18));
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k2), UNITS / 2, d, 0);
        assertEq(lpVault.depositorOf(k2), alice, "still in custody");
        assertEq(token.totalSupply(), UNITS + UNITS / 2, "nothing burned");
        risk.setHardFloor(0);
        _withdraw(k2, UNITS / 2, 1.6e18);
    }

    // TEST-019 verifies: REQ-PROXY-077, REQ-PROXY-096
    /// @notice A withdrawal Aave refuses (health factor below 1) reverts in the Spoke.
    function test_TEST_019_aaveRefusesBelowOne() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 10_000e18);
        uint256 d = _deadline();
        vm.expectRevert();
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k1), UNITS, d, 0);
    }

    // TEST-019 verifies: REQ-PROXY-063, REQ-PROXY-066, REQ-ADAPTER-008
    /// @notice A RiskModule pre-check error propagates unchanged.
    function test_TEST_019_preWithdrawErrorPropagates() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 100e18);
        risk.setRefuse(true);
        _expectWithdrawRevert(abi.encodeWithSelector(IRiskModuleErrors.SequencerDown.selector), k2, UNITS / 2);
    }

    // TEST-203 verifies: REQ-PROXY-034, SPEC-PROXY-006
    /// @notice Debt-free means zero debt on every reserve: one USDC base unit of debt sends the withdrawal down the
    /// with-debt path.
    function test_TEST_203_oneBaseUnitIsDebt() public {
        _borrowAs(alice, MARKET_ID, usdcReserveId, 1);
        vm.expectCall(address(risk), abi.encodeCall(IRiskModuleChecks.preWithdrawCheck, (p)), 1);
        _withdraw(k2, UNITS / 2, 0);
    }

    // ─── Bounds ───

    // TEST-018 verifies: REQ-PROXY-033, REQ-PROXY-057, REQ-PROXY-058, REQ-PROXY-060, REQ-PROXY-062
    /// @notice Deadline, proxy, zero units and integration are checked in that order.
    function test_TEST_018_checkOrder() public {
        uint256 past = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.DeadlineExpired.selector, past));
        vm.prank(bob);
        adapterC.withdraw(MARKET_ID, PositionRef(9, k1), 0, past, 0);
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.NoProxy.selector, bob, MARKET_ID));
        vm.prank(bob);
        adapterC.withdraw(MARKET_ID, PositionRef(9, k1), 0, d, 0);
        vm.expectRevert(IAaveAdapterErrors.ZeroAmount.selector);
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, PositionRef(9, k1), 0, d, 0);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.IntegrationMismatch.selector, MARKET_ID, 9));
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, PositionRef(9, k1), UNITS, d, 0);
    }

    // TEST-018 verifies: REQ-PROXY-082, REQ-PROXY-038
    /// @notice Units other than the record's credited units fail in Collateralization with `UnitsMismatch`, undoing
    /// the Spoke withdrawal and the burn.
    function test_TEST_018_unitsMustEqualCredited() public {
        _expectWithdrawRevert(abi.encodeWithSelector(ICollateralizationErrors.UnitsMismatch.selector), k1, UNITS / 2);
        assertEq(_sharesOf(p, vtReserveId), UNITS + UNITS / 2, "nothing withdrawn");
    }

    // TEST-026 verifies: REQ-ADAPTER-066, REQ-PROXY-033, ATTACK-010
    /// @notice A wallet cannot withdraw another wallet's record: its own proxy is not the record's.
    function test_TEST_026_cannotWithdrawOthersRecord() public {
        _pledgeAs(bob, MARKET_ID, UNITS);
        uint256 d = _deadline();
        vm.expectRevert(ICollateralizationErrors.NotRecordProxy.selector);
        vm.prank(bob);
        adapterC.withdraw(MARKET_ID, _ref(k1), UNITS, d, 0);
    }

    // TEST-209 verifies: REQ-ADAPTER-069, REQ-ADAPTER-075, SPEC-PROXY-008
    /// @notice A Collateralization that skips the debit makes the burn unmatched: `BackingMismatch`.
    function test_TEST_209_skippedDebitRevertsBackingMismatch() public {
        vm.mockCall(address(coll), abi.encodeWithSelector(ICollateralizationAdapter.release.selector), "");
        uint256 supplyAfter = UNITS / 2;
        uint256 credited = UNITS + UNITS / 2;
        _expectWithdrawRevert(
            abi.encodeWithSelector(IAaveAdapterErrors.BackingMismatch.selector, supplyAfter, credited, 0), k1, UNITS
        );
    }

    // TEST-060 verifies: REQ-PROXY-048, REQ-PROXY-076
    function test_TEST_060_withdrawUnderHeldLock() public {
        bytes memory data = abi.encodeCall(adapterC.withdraw, (MARKET_ID, _ref(k1), UNITS, _deadline(), 0));
        vm.prank(alice);
        bytes memory err = swap.callUnderLock(adapter, data);
        assertEq(err, abi.encodeWithSelector(ILock.LockHeld.selector, address(swap)), "LockHeld");
    }

    // ─── Reconciliation after an unsettled seizure ───

    // TEST-150 verifies: REQ-PROXY-037, REQ-PROXY-038, REQ-PROXY-082, INV-058, Q-201
    // Sources: 5.1 TEST-150
    /// @notice After a liquidation that kept the seized units and never called Collateralization, a withdrawal sized
    /// before it fails `UnitsMismatch`; one sized with `previewRelease` reconciles and returns the position.
    function test_TEST_150_withdrawAfterUnsettledSeizure() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 20_000e18);
        vtPrice.set(1.5e8); // $22,500 × 0.80 = $18,000 < $20,000: liquidatable
        uint256 seized = swap.seizeAndKeep(aave.cdpSpoke, vt, vtReserveId, debtReserveId, p, 5000e18);
        assertGt(seized, 0, "seized");
        uint256 debtLeft = _debtOf(p, debtReserveId);
        _fund(alice, debtReserveId, debtLeft);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, debtLeft, true, _deadline());
        // The list starts with the larger record k1, so the shortfall is debited from it.
        _expectWithdrawRevert(abi.encodeWithSelector(ICollateralizationErrors.UnitsMismatch.selector), k1, UNITS);
        uint256 units = coll.previewRelease(INTEGRATION, k1);
        assertEq(units, UNITS - seized, "reconciled from the head of the list");
        _withdraw(k1, units, 0);
        assertEq(lpVault.ownerOf(k1), alice, "position returned");
        assertEq(coll.previewRelease(INTEGRATION, k2), UNITS / 2, "k2 untouched");
    }

    // ─── repayAllAndWithdraw ───

    // TEST-203 verifies: REQ-ADAPTER-071, REQ-ADAPTER-085, REQ-PROXY-031, REQ-PROXY-034, WDR-024, Q-234
    // Sources: 5.1 TEST-203, 2.6 two-reserve worked example
    /// @notice Naming both debt reserves repays each in full from the caller (two `Repaid`, refunds to the caller),
    /// then withdraws debt-free; naming only GHO while USDC remains reverts `DebtRemaining(usdc, debt)`.
    function test_TEST_203_repayAllAndWithdraw() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 8000e18);
        _borrowAs(alice, MARKET_ID, usdcReserveId, 5000e6);
        vm.warp(block.timestamp + 30 days);
        uint256 g = _debtOf(p, debtReserveId);
        uint256 u = _debtOf(p, usdcReserveId);
        _fund(alice, debtReserveId, 8040e18);
        _fund(alice, usdcReserveId, 5030e6);
        uint256[] memory onlyGho = new uint256[](1);
        onlyGho[0] = debtReserveId;
        uint256[] memory onlyGhoCap = new uint256[](1);
        onlyGhoCap[0] = 8040e18;
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.DebtRemaining.selector, usdcReserveId, u));
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(MARKET_ID, _ref(k2), UNITS / 2, onlyGho, onlyGhoCap, d);
        uint256[] memory ids = new uint256[](2);
        ids[0] = debtReserveId;
        ids[1] = usdcReserveId;
        uint256[] memory caps = new uint256[](2);
        caps[0] = 8040e18;
        caps[1] = 5030e6;
        uint256 ghoBefore = debt.balanceOf(alice);
        uint256 usdcBefore = usdcDebt.balanceOf(alice);
        vm.expectEmit(adapter);
        emit IAaveAdapterEvents.Repaid(alice, alice, MARKET_ID, debtReserveId, g, 0, true);
        vm.expectEmit(adapter);
        emit IAaveAdapterEvents.Repaid(alice, alice, MARKET_ID, usdcReserveId, u, 0, true);
        vm.expectEmit(adapter);
        emit IAaveAdapterEvents.CollateralWithdrawn(alice, MARKET_ID, vt, k2, UNITS / 2, false, type(uint256).max);
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(MARKET_ID, _ref(k2), UNITS / 2, ids, caps, d);
        assertEq(ghoBefore - debt.balanceOf(alice), g, "GHO spent the debt");
        assertEq(usdcBefore - usdcDebt.balanceOf(alice), u, "USDC spent the debt");
        assertEq(_borrowCountOf(p), 0, "debt-free");
        assertEq(lpVault.ownerOf(k2), alice, "position returned");
        assertTrue(coll.getMarketDebtFree(vt), "mark cleared");
    }

    // TEST-203 verifies: REQ-ADAPTER-076, REQ-ADAPTER-071
    function test_TEST_203_lengthMismatch() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory caps = new uint256[](1);
        uint256 d = _deadline();
        vm.expectRevert(IAaveAdapterErrors.LengthMismatch.selector);
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(MARKET_ID, _ref(k1), UNITS, ids, caps, d);
    }

    // TEST-165 verifies: REQ-ADAPTER-071, REQ-PROXY-069
    /// @notice A listed reserve already at 0 is skipped with no transfer and no event, and the call proceeds to the
    /// withdrawal once the account is debt-free.
    function test_TEST_165_repayAllSkipsZeroDebtReserves() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = debtReserveId;
        ids[1] = usdcReserveId;
        uint256[] memory caps = new uint256[](2);
        caps[0] = 1e18;
        caps[1] = 1e6;
        vm.expectCall(address(debt), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
        vm.expectCall(address(usdcDebt), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(MARKET_ID, _ref(k1), UNITS, ids, caps, _deadline());
        assertEq(lpVault.ownerOf(k1), alice, "withdrawn");
    }

    // TEST-243 verifies: REQ-ADAPTER-071, REQ-ADAPTER-047, REQ-ADAPTER-086, REQ-PROXY-034, ATTACK-035
    // Sources: real-Aave list (exits with a reverting registry or RiskModule)
    /// @notice `repayAllAndWithdraw` completes with a reverting MarketRegistry and RiskModule, for a frozen wallet under
    /// `Paused(MintPathSuspect)`.
    function test_TEST_243_repayAllAndWithdrawIgnoresEveryStop() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 3000e18);
        uint256 g = _debtOf(p, debtReserveId);
        _fund(alice, debtReserveId, g);
        _breakEverything();
        uint256[] memory ids = new uint256[](1);
        ids[0] = debtReserveId;
        uint256[] memory caps = new uint256[](1);
        caps[0] = g;
        vm.expectCall(address(registry), "", 0);
        vm.expectCall(address(risk), "", 0);
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(MARKET_ID, _ref(k1), UNITS, ids, caps, _deadline());
        assertEq(lpVault.ownerOf(k1), alice, "exit completed");
    }

    // TEST-203 verifies: REQ-ADAPTER-071, REQ-PROXY-071
    /// @notice With no reserve named and debt outstanding, `DebtRemaining` names the first reserve the Spoke reports
    /// borrowed.
    function test_TEST_203_debtRemainingNamesFirstBorrowed() public {
        _borrowAs(alice, MARKET_ID, usdcReserveId, 100e6);
        _borrowAs(alice, MARKET_ID, debtReserveId, 100e18);
        uint256 first = debtReserveId < usdcReserveId ? debtReserveId : usdcReserveId;
        uint256 owed = _debtOf(p, first);
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.DebtRemaining.selector, first, owed));
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(MARKET_ID, _ref(k1), UNITS, new uint256[](0), new uint256[](0), d);
    }

    // TEST-203 verifies: REQ-ADAPTER-071, REQ-PROXY-070
    /// @notice A cap below a named reserve's debt reverts `RepayExceedsMax` before any transfer.
    function test_TEST_203_capBelowDebt() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 100e18);
        uint256[] memory ids = new uint256[](1);
        ids[0] = debtReserveId;
        uint256[] memory caps = new uint256[](1);
        caps[0] = 99e18;
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.RepayExceedsMax.selector, 100e18, 99e18));
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(MARKET_ID, _ref(k1), UNITS, ids, caps, d);
    }

    // TEST-018 verifies: REQ-ADAPTER-071
    /// @notice `repayAllAndWithdraw` checks its bounds in order: deadline, lengths, proxy, units, integration.
    function test_TEST_018_repayAllCheckOrder() public {
        uint256 past = block.timestamp - 1;
        uint256[] memory two = new uint256[](2);
        uint256[] memory one = new uint256[](1);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.DeadlineExpired.selector, past));
        vm.prank(bob);
        adapterC.repayAllAndWithdraw(MARKET_ID, PositionRef(9, k1), 0, two, one, past);
        uint256 d = _deadline();
        vm.expectRevert(IAaveAdapterErrors.LengthMismatch.selector);
        vm.prank(bob);
        adapterC.repayAllAndWithdraw(MARKET_ID, PositionRef(9, k1), 0, two, one, d);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.NoProxy.selector, bob, MARKET_ID));
        vm.prank(bob);
        adapterC.repayAllAndWithdraw(MARKET_ID, PositionRef(9, k1), 0, one, one, d);
        vm.expectRevert(IAaveAdapterErrors.ZeroAmount.selector);
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(MARKET_ID, PositionRef(9, k1), 0, one, one, d);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.IntegrationMismatch.selector, MARKET_ID, 9));
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(MARKET_ID, PositionRef(9, k1), UNITS, one, one, d);
    }

    // ─── Fee collection and zero-credit release ───

    // TEST-060 verifies: REQ-ADAPTER-096, REQ-ADAPTER-047, REQ-LOCK-028, INV-044
    // Sources: 2.6 REQ-ADAPTER-096
    /// @notice Fee collection runs through the Adapter's Lock, pays the depositor of record and leaves units, supply
    /// and health factor unchanged; it reads no registry or RiskModule.
    function test_TEST_060_collectFees() public {
        lpVault.accrueFees(k1, 16_500_000);
        registry.setBroken(true);
        risk.setBroken(true);
        vm.prank(alice);
        uint256[] memory fees = adapterC.collectFees(MARKET_ID, _ref(k1), _deadline());
        assertEq(fees.length, 2, "two tokens");
        assertEq(fees[0], 16_500_000, "USDC fee");
        assertEq(usdc.balanceOf(alice), 16_500_000, "paid to the depositor");
        assertEq(_sharesOf(p, vtReserveId), UNITS + UNITS / 2, "units unchanged");
        assertFalse(lock.isLocked(), "lock free");
    }

    // TEST-060 verifies: REQ-ADAPTER-096, REQ-ADAPTER-101
    /// @notice Only the depositor of record collects: a wallet without an account has no proxy, one with an account
    /// is not the depositor; a wrong integration reverts.
    function test_TEST_060_collectFeesBounds() public {
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.NoProxy.selector, bob, MARKET_ID));
        vm.prank(bob);
        adapterC.collectFees(MARKET_ID, _ref(k1), d);
        _pledgeAs(bob, MARKET_ID, UNITS);
        vm.expectRevert(ICollateralizationErrors.NotDepositor.selector);
        vm.prank(bob);
        adapterC.collectFees(MARKET_ID, _ref(k1), d);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.IntegrationMismatch.selector, MARKET_ID, 9));
        vm.prank(alice);
        adapterC.collectFees(MARKET_ID, PositionRef(9, k1), d);
        uint256 past = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.DeadlineExpired.selector, past));
        vm.prank(alice);
        adapterC.collectFees(MARKET_ID, _ref(k1), past);
    }

    // TEST-151 verifies: REQ-ADAPTER-097, REQ-ADAPTER-047, INV-044, Q-201
    /// @notice A record whose credit a liquidation took to 0 is returned by `releaseZeroCredit`; a record with credit
    /// is refused with `RecordHasCredit`.
    function test_TEST_151_releaseZeroCredit() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 20_000e18);
        vtPrice.set(1.2e8);
        swap.liquidate(aave.cdpSpoke, MARKET_ID, vt, vtReserveId, debtReserveId, p, 20_000e18, 2);
        uint256 d = _deadline();
        bytes32 zero;
        bytes32 left;
        if (coll.getRecord(coll.recordIdOf(INTEGRATION, k1)).credited == 0) (zero, left) = (k1, k2);
        else (zero, left) = (k2, k1);
        assertEq(coll.getRecord(coll.recordIdOf(INTEGRATION, zero)).credited, 0, "a record at zero credit");
        registry.setBroken(true);
        vm.prank(alice);
        adapterC.releaseZeroCredit(MARKET_ID, _ref(zero), d);
        assertEq(lpVault.ownerOf(zero), alice, "returned");
        if (coll.getRecord(coll.recordIdOf(INTEGRATION, left)).credited != 0) {
            vm.expectRevert(ICollateralizationErrors.RecordHasCredit.selector);
            vm.prank(alice);
            adapterC.releaseZeroCredit(MARKET_ID, _ref(left), d);
        }
    }

    // ─── Debt mark ───

    // TEST-099 verifies: REQ-ADAPTER-104, REQ-COLL-040, Q-355
    /// @notice A mark left set because the Spoke read failed in the repay is cleared by anyone through
    /// `refreshDebtMark`, which reads no registry; on an indebted account it changes nothing.
    function test_TEST_099_refreshDebtMark() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 100e18);
        uint256 g = _debtOf(p, debtReserveId);
        _fund(alice, debtReserveId, g);
        vm.mockCallRevert(aave.cdpSpoke, abi.encodeCall(IAaveV4Spoke.getUserAccountData, (p)), "down");
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, g, true, _deadline());
        vm.clearMockedCalls();
        assertFalse(coll.getMarketDebtFree(vt), "stale mark");
        registry.setBroken(true);
        vm.expectCall(address(coll), abi.encodeCall(ICollateralizationDebtMark.markDebtFree, (p)), 1);
        vm.prank(attacker);
        adapterC.refreshDebtMark(p);
        assertTrue(coll.getMarketDebtFree(vt), "cleared");
        assertFalse(lock.isLocked(), "lock free");
    }

    // TEST-099 verifies: REQ-ADAPTER-104
    function test_TEST_099_refreshDebtMarkIndebtedNoop() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 100e18);
        vm.prank(attacker);
        adapterC.refreshDebtMark(p);
        assertFalse(coll.getMarketDebtFree(vt), "still marked");
        vm.prank(attacker);
        adapterC.refreshDebtMark(makeAddr("notAProxy"));
    }
}
