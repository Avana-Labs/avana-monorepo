// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationViews} from "../../src/custody/collateralization/ICollateralizationViews.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILensErrors} from "../../src/lens/lens/ILensErrors.sol";
import {CloseAccountView} from "../../src/lens/lens/types/CloseAccountView.sol";
import {DeleverageSizing} from "../../src/lens/lens/types/DeleverageSizing.sol";
import {RemovalSizing} from "../../src/lens/lens/types/RemovalSizing.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {RiskModuleMath} from "../../src/policy/risk-module/RiskModuleMath.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensInverseSizingUnitTest
/// @notice `previewMaxWithdraw`, `previewDeleverageTo` and `previewCloseAccount` on the real Aave V4 Spoke and
/// Collateralization: the removal bound is the exact largest one Aave keeps at the target, the deleverage sizing reaches
/// the target with the fewest units its arithmetic allows, and the close-account preview lists every debt with its
/// repay-all quote and every record with its withdrawal units.
/// forge-config: default.isolate = false
contract LensInverseSizingUnitTest is LensFixture {
    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, 10_000e6);
    }

    /// @dev Aave's health factor after the proxy withdraws `units` straight from the Spoke, state restored.
    function _hfAfterSpokeWithdraw(
        uint256 units
    ) internal returns (uint256 hf) {
        uint256 snap = vm.snapshotState();
        vm.prank(aliceProxy);
        IAaveV4Spoke(aave.cdpSpoke).withdraw(vtReserveId, units, aliceProxy);
        hf = _hf(aliceProxy);
        vm.revertToState(snap);
    }

    // ─── previewMaxWithdraw ───

    // TEST-247 verifies: REQ-LENS-054, REQ-LENS-005
    function test_TEST_247_maxWithdrawWithoutDebtIsEveryRecord() public {
        _pledge(alice, aliceProxy, _key(2), 4000e6);
        RemovalSizing memory s = lens.previewMaxWithdraw(alice, MARKET_ID, 3e18);
        assertEq(s.blockNumber, block.number, "block");
        assertEq(s.proxy, aliceProxy, "proxy");
        assertEq(s.target, 3e18, "no debt: the target is not raised");
        assertEq(s.maxUnits, 14_000e6, "every credited unit");
        assertEq(s.records.length, 2, "two records");
        assertEq(s.records[0].positionKey, _key(1), "largest first");
        assertEq(s.records[0].units, 10_000e6, "record 1");
        assertTrue(s.records[0].fits && s.records[1].fits, "both fit");
        assertEq(s.bestIndex, 0, "the largest");
    }

    // TEST-247 verifies: REQ-LENS-054
    function test_TEST_247_maxWithdrawIsTheExactAaveBound() public {
        _pledge(alice, aliceProxy, _key(2), 6000e6);
        _borrow(aliceProxy, 10_000e18);
        RemovalSizing memory s = lens.previewMaxWithdraw(alice, MARKET_ID, 1.25e18);
        assertEq(s.target, 1.25e18, "above 1.00");
        // W = 0.8 x $32,000 = $25,600; need = 1.25 x $10,000 = $12,500; (25,600 - 12,500) / (0.8 x $2) = 8,187.5.
        assertEq(s.maxUnits, 8_187_500_000, "8,187.5 vault tokens");
        assertGe(_hfAfterSpokeWithdraw(s.maxUnits), 1.25e18, "the bound keeps the target");
        assertLt(_hfAfterSpokeWithdraw(s.maxUnits + 1), 1.25e18, "one unit more does not");
        assertFalse(s.records[0].fits, "10,000 do not fit");
        assertTrue(s.records[1].fits, "6,000 fit");
        assertEq(s.bestIndex, 1, "the 6,000 record");
        _withdraw(aliceProxy, _key(2), 6000e6);
        assertEq(_hf(aliceProxy), 1.6e18, "after the withdrawal: 0.8 x 20,000 / 10,000");
    }

    // TEST-247 verifies: REQ-LENS-054
    function test_TEST_247_maxWithdrawTargetRaisedToTheFloorAndOne() public {
        _borrow(aliceProxy, 8000e18);
        RemovalSizing memory s = lens.previewMaxWithdraw(alice, MARKET_ID, 0.5e18);
        assertEq(s.target, 1e18, "never below 1.00 with debt");
        assertEq(s.maxUnits, 5000e6, "(16,000 - 8,000) / 1.6");
        assertFalse(s.records[0].fits, "the only record does not fit");
        assertEq(s.bestIndex, type(uint256).max, "none fits");
        store.setHardHealthFloor(MARKET_ID, 1.6e18);
        s = lens.previewMaxWithdraw(alice, MARKET_ID, 1.2e18);
        assertEq(s.target, 1.6e18, "the market's hard floor");
        assertEq(s.maxUnits, 2000e6, "(16,000 - 12,800) / 1.6");
        assertEq(lens.previewMaxWithdraw(alice, MARKET_ID, 2e18).maxUnits, 0, "already at the target");
    }

    // TEST-247 verifies: REQ-LENS-054, SPEC-CF-005
    function test_TEST_247_maxWithdrawSubtractsTheRescueExclusion() public {
        _borrow(aliceProxy, 8000e18);
        vm.mockCall(
            address(coll),
            abi.encodeCall(ICollateralizationViews.getAccountRescueUnits, (aliceProxy, vt)),
            abi.encode(uint256(1000e6))
        );
        uint256 e = RiskModuleMath.rescueValue(1000e6, 2e8, 8000, VT_DECIMALS);
        assertEq(e, 1600e26, "1,000 tokens x $2 x 0.8");
        RemovalSizing memory s = lens.previewMaxWithdraw(alice, MARKET_ID, 1e18);
        vm.clearMockedCalls();
        assertEq(s.maxUnits, 4000e6, "(16,000 - 1,600 - 8,000) / 1.6");
    }

    // TEST-247 verifies: REQ-LENS-054
    function test_TEST_247_maxWithdrawClosedGatesAndNoAccount() public {
        _borrow(aliceProxy, 1000e18);
        rm.setGate(aliceProxy, false, false, PauseState.None);
        assertEq(lens.previewMaxWithdraw(alice, MARKET_ID, 1e18).maxUnits, 0, "withdraw-with-debt closed");
        rm.setGate(aliceProxy, true, false, PauseState.Paused);
        assertEq(lens.previewMaxWithdraw(alice, MARKET_ID, 1e18).maxUnits, 0, "Paused");
        rm.setGate(aliceProxy, true, false, PauseState.Frozen);
        assertGt(lens.previewMaxWithdraw(alice, MARKET_ID, 1e18).maxUnits, 0, "Frozen leaves it open");
        reg.setFrozen(alice, true);
        RemovalSizing memory s = lens.previewMaxWithdraw(alice, MARKET_ID, 1e18);
        assertEq(s.maxUnits, 0, "a frozen wallet");
        assertFalse(s.records[0].fits, "nothing fits");
        s = lens.previewMaxWithdraw(bob, MARKET_ID, 1e18);
        assertEq(s.records.length, 0, "no proxy");
        assertEq(s.maxUnits, 0, "nothing");
        assertEq(s.bestIndex, type(uint256).max, "no record");
    }

    // TEST-247 verifies: REQ-LENS-054
    function test_TEST_247_maxWithdrawUsesTheLatestFactorAndCapsAtTheAssets() public {
        _borrow(aliceProxy, 1e18);
        _spokeConfig(
            abi.encodeWithSignature("addCollateralFactor(address,uint256,uint16)", aave.cdpSpoke, vtReserveId, 5000)
        );
        RemovalSizing memory s = lens.previewMaxWithdraw(alice, MARKET_ID, 1e18);
        // (0.5 x 20,000 - 1) / (0.5 x 2) = 9,999 tokens at the latest factor.
        assertEq(s.maxUnits, 9999e6, "the latest 50 %");
        assertGe(_hfAfterSpokeWithdraw(s.maxUnits), 1e18, "Aave accepts it");
        _repay(1e18);
        assertEq(lens.previewMaxWithdraw(alice, MARKET_ID, 1e18).maxUnits, 10_000e6, "no debt left: all");
    }

    // ─── previewDeleverageTo ───

    // TEST-247 verifies: REQ-LENS-055, REQ-LENS-005
    function test_TEST_247_deleverageToReachesTheTargetWithTheFewestUnits() public {
        _borrow(aliceProxy, 12_000e18);
        DeleverageSizing memory s = lens.previewDeleverageTo(alice, MARKET_ID, _key(1), debtReserveId, 1.6e18);
        assertTrue(s.reachable, "reachable");
        assertEq(s.proxy, aliceProxy, "proxy");
        assertGe(s.healthFactorAfter, 1.6e18, "at or above the target");
        (uint256 x, uint256 out, uint256 hf) =
            lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), uint128(s.units), debtReserveId);
        assertEq(s.debtRepaid, x, "same x as the preview");
        assertEq(s.debtAssetToWallet, out, "same payout");
        assertEq(s.healthFactorAfter, hf, "same health factor");
        (,, hf) = lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), uint128(s.units - 1), debtReserveId);
        assertLt(hf, 1.6e18, "one unit fewer misses the target");
    }

    // TEST-247 verifies: REQ-LENS-055
    function test_TEST_247_deleverageToAlreadyAtTargetOrUnreachable() public {
        _borrow(aliceProxy, 4000e18);
        DeleverageSizing memory s = lens.previewDeleverageTo(alice, MARKET_ID, _key(1), debtReserveId, 2e18);
        assertTrue(s.reachable, "HF 4.0 is above 2.0");
        assertEq(s.units, 0, "nothing to do");
        assertEq(s.healthFactorAfter, 4e18, "the current health factor");
        // A second debt the record cannot clear: repaying all GHO still leaves USDC above the target.
        _borrowUsdc(aliceProxy, 9000e6);
        s = lens.previewDeleverageTo(alice, MARKET_ID, _key(1), debtReserveId, 50e18);
        assertFalse(s.reachable, "unreachable");
        assertEq(s.units + s.debtRepaid + s.healthFactorAfter, 0, "every amount 0");
        // Clearing the USDC debt from the record leaves the GHO debt, still short of the target.
        s = lens.previewDeleverageTo(alice, MARKET_ID, _key(1), usdcReserveId, 50e18);
        assertFalse(s.reachable, "the GHO debt stays");
    }

    // TEST-247 verifies: REQ-LENS-055
    function test_TEST_247_deleverageToClearingTheOnlyDebt() public {
        _borrow(aliceProxy, 2000e18);
        // Only a cleared debt reaches the largest target.
        DeleverageSizing memory s =
            lens.previewDeleverageTo(alice, MARKET_ID, _key(1), debtReserveId, type(uint256).max);
        assertTrue(s.reachable, "clearing the debt reaches it");
        assertEq(s.debtRepaid, 2000e18, "the whole debt");
        assertEq(s.healthFactorAfter, type(uint256).max, "no debt");
        (uint256 x,,) = lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), uint128(s.units - 1), debtReserveId);
        assertLt(x, 2000e18, "one unit fewer does not clear it");
    }

    // TEST-247 verifies: REQ-LENS-055, REQ-LENS-032
    function test_TEST_247_deleverageToClosedOrUnknown() public {
        _borrow(aliceProxy, 12_000e18);
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.General);
        assertFalse(lens.previewDeleverageTo(alice, MARKET_ID, _key(1), debtReserveId, 1.6e18).reachable, "Paused");
        reg.setPause(aave.hub, PauseState.None, PauseReason.None);
        assertFalse(lens.previewDeleverageTo(bob, MARKET_ID, _key(1), debtReserveId, 1.6e18).reachable, "not his");
        assertFalse(lens.previewDeleverageTo(alice, MARKET_ID, _key(1), usdcReserveId, 1.6e18).reachable, "no USDC");
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.UnknownDebtReserve.selector, aave.cdpSpoke, 7));
        lens.previewDeleverageTo(alice, MARKET_ID, _key(1), 7, 1.6e18);
    }

    // ─── previewCloseAccount ───

    // TEST-247 verifies: REQ-LENS-056, REQ-LENS-036, REQ-LENS-005
    function test_TEST_247_closeAccountListsDebtsAndRecords() public {
        _pledge(alice, aliceProxy, _key(2), 3000e6);
        _borrow(aliceProxy, 5000e18);
        _borrowUsdc(aliceProxy, 1000e6);
        vm.warp(block.timestamp + 10 days);
        uint256 deadline = block.timestamp + 1200;
        CloseAccountView memory c = lens.previewCloseAccount(alice, MARKET_ID, deadline);
        assertEq(c.blockNumber, block.number, "block");
        assertEq(c.proxy, aliceProxy, "proxy");
        assertEq(c.debts.length, 2, "two debts");
        assertEq(c.debts[0].reserveId, debtReserveId, "GHO first, in reserve order");
        assertEq(c.debts[0].asset, address(debt), "asset");
        assertEq(c.debts[0].total, _debtOf(aliceProxy, debtReserveId), "total");
        assertEq(
            c.debts[0].maxRepaySpend, lens.quoteRepayAll(alice, MARKET_ID, debtReserveId, deadline), "repay-all quote"
        );
        assertEq(c.debts[1].maxRepaySpend, lens.quoteRepayAll(alice, MARKET_ID, usdcReserveId, deadline), "USDC");
        assertEq(c.records.length, 2, "two records");
        assertEq(c.records[0].units, 10_000e6, "record 1 units");
        assertEq(c.records[1].positionKey, _key(2), "record 2");
        (uint256[] memory amounts,) = vault.composition(MARKET_ID, 3000e6, _prices());
        assertEq(c.records[1].amounts, amounts, "composition at the oracle prices");
    }

    // TEST-247 verifies: REQ-LENS-056
    function test_TEST_247_closeAccountWithoutDebtOrPriceOrAccount() public {
        CloseAccountView memory c = lens.previewCloseAccount(alice, MARKET_ID, block.timestamp);
        assertEq(c.debts.length, 0, "no debt");
        assertEq(c.records.length, 1, "one record");
        lpo.setTokenPrice(1, 0);
        c = lens.previewCloseAccount(alice, MARKET_ID, block.timestamp);
        assertEq(c.records[0].amounts.length, 2, "one zero per token");
        assertEq(c.records[0].amounts[0] + c.records[0].amounts[1], 0, "no price, no amounts");
        c = lens.previewCloseAccount(bob, MARKET_ID, block.timestamp);
        (address predicted,) = lens.predictProxy(bob, MARKET_ID);
        assertEq(c.proxy, predicted, "the predicted proxy");
        assertEq(c.debts.length + c.records.length, 0, "nothing to close");
    }

    // TEST-247 verifies: REQ-LENS-056
    function test_TEST_247_closeAccountRecordAfterASeizureUsesReconciledUnits() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.8e8);
        _seizeAndKeep(aliceProxy, 1000e18);
        CloseAccountView memory c = lens.previewCloseAccount(alice, MARKET_ID, block.timestamp);
        assertEq(c.records[0].units, coll.previewRelease(INTEGRATION, _key(1)), "credited units after reconciliation");
        assertLt(c.records[0].units, 10_000e6, "the seized units are gone");
    }

    // ─── failures ───

    // TEST-247 verifies: REQ-LENS-006, REQ-LENS-021, REQ-LENS-022
    function test_TEST_247_sizingRevertsWhenLockedOrUnknown() public {
        _holdLock();
        vm.expectRevert(ILensErrors.Locked.selector);
        lens.previewMaxWithdraw(alice, MARKET_ID, 1e18);
        vm.expectRevert(ILensErrors.Locked.selector);
        lens.previewDeleverageTo(alice, MARKET_ID, _key(1), debtReserveId, 1e18);
        vm.expectRevert(ILensErrors.Locked.selector);
        lens.previewCloseAccount(alice, MARKET_ID, 0);
        _releaseLock();
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.UnknownMarket.selector, 5));
        lens.previewMaxWithdraw(alice, 5, 1e18);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.UnknownMarket.selector, 5));
        lens.previewDeleverageTo(alice, 5, _key(1), debtReserveId, 1e18);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.UnknownMarket.selector, 5));
        lens.previewCloseAccount(alice, 5, 0);
    }

    function _repay(
        uint256 amount
    ) internal {
        debt.mint(aliceProxy, amount);
        vm.startPrank(aliceProxy);
        debt.approve(aave.cdpSpoke, amount);
        IAaveV4Spoke(aave.cdpSpoke).repay(debtReserveId, amount, aliceProxy);
        vm.stopPrank();
    }

    function _prices() internal view returns (uint256[] memory prices) {
        (prices,,) = lpo.getTokenPrices();
    }
}
