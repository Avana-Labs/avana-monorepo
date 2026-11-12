// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {AccountRiskView} from "../../src/lens/lens/types/AccountRiskView.sol";
import {PledgePreviewView} from "../../src/lens/lens/types/PledgePreviewView.sol";
import {WithdrawPreview} from "../../src/lens/lens/types/WithdrawPreview.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensPositionsUnitTest
/// @notice `getAccountRisk`, `previewPledge` and `previewWithdraw` on the real Aave V4 Spoke and Collateralization: the
/// liquidation price checked against Aave's own health factor at the price and one unit below, and the withdrawal
/// preview checked against the withdrawal itself.
/// forge-config: default.isolate = false
contract LensPositionsUnitTest is LensFixture {
    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, 10_000e6);
    }

    // ─── liquidation price ───

    // TEST-247 verifies: REQ-LENS-047, REQ-LENS-005
    function test_TEST_247_liquidationPriceExample() public {
        _borrow(aliceProxy, 15_000e18);
        AccountRiskView memory v = lens.getAccountRisk(alice, MARKET_ID);
        assertEq(v.blockNumber, block.number, "block");
        assertEq(v.proxy, aliceProxy, "proxy");
        assertEq(v.liquidationPrice, 187_500_000, "15,000 / (0.8 x 10,000) = $1.875");
        _assertBoundary(v.liquidationPrice);
    }

    // TEST-247 verifies: REQ-LENS-047
    function test_TEST_247_liquidationPriceWithTwoDebtsAndInterest() public {
        _borrow(aliceProxy, 7000e18);
        _borrowUsdc(aliceProxy, 5000e6);
        vm.warp(block.timestamp + 90 days);
        _setUsdcPrice(1.01e8);
        uint256 p = lens.getAccountRisk(alice, MARKET_ID).liquidationPrice;
        assertGt(p, 0, "debt");
        _assertBoundary(p);
    }

    // TEST-247 verifies: REQ-LENS-047
    function test_TEST_247_liquidationPriceZeroWithoutDebtAndMaxWithoutCollateral() public {
        assertEq(lens.getAccountRisk(alice, MARKET_ID).liquidationPrice, 0, "no debt");
        assertEq(lens.getAccountRisk(bob, MARKET_ID).liquidationPrice, 0, "no account");
        _borrow(aliceProxy, 1000e18);
        // The account's own dynamic configuration counts its collateral at a zero factor.
        vm.mockCall(
            aave.cdpSpoke,
            abi.encodeWithSignature("getDynamicReserveConfig(uint256,uint32)", vtReserveId, uint32(0)),
            abi.encode(IAaveV4Spoke.DynamicReserveConfig(0, 10_500, 0))
        );
        assertEq(lens.getAccountRisk(alice, MARKET_ID).liquidationPrice, type(uint256).max, "no counted collateral");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-047
    function test_TEST_247_borrowRatesIncludeRiskPremium() public {
        _borrow(aliceProxy, 8000e18);
        AccountRiskView memory v = lens.getAccountRisk(alice, MARKET_ID);
        assertEq(v.reserveIds.length, 2, "one rate per enabled reserve");
        assertEq(v.reserveIds[0], debtReserveId, "GHO");
        uint256 rp = IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(aliceProxy).riskPremium;
        assertEq(v.borrowRatesRay[0], Math.mulDiv(_rate(ghoAssetId), 1e4 + rp, 1e4, Math.Rounding.Ceil), "GHO rate");
        assertEq(v.borrowRatesRay[1], Math.mulDiv(_rate(usdcAssetId), 1e4 + rp, 1e4, Math.Rounding.Ceil), "USDC");
        vm.mockCall(aave.hub, abi.encodeWithSignature("getAssetDrawnRate(uint256)", ghoAssetId), abi.encode(0.08e27));
        vm.mockCall(
            aave.cdpSpoke,
            abi.encodeWithSignature("getUserAccountData(address)", aliceProxy),
            abi.encode(IAaveV4Spoke.UserAccountData(1500, 0, 0, 0, 0, 0, 0))
        );
        assertEq(lens.getAccountRisk(alice, MARKET_ID).borrowRatesRay[0], 0.092e27, "8 % x (1 + 15 %)");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-047, REQ-LENS-006
    function test_TEST_247_accountRiskRefusesWhileLocked() public {
        _holdLock();
        vm.expectRevert(bytes4(keccak256("Locked()")));
        lens.getAccountRisk(alice, MARKET_ID);
        _releaseLock();
    }

    // ─── previewPledge ───

    // TEST-247 verifies: REQ-LENS-048, REQ-LENS-005
    function test_TEST_247_previewPledgePassThrough() public {
        rm.setPledgePreview(true, bytes4(0), 1234e8);
        PledgePreviewView memory v = lens.previewPledge(bob, MARKET_ID, _key(9));
        assertEq(v.blockNumber, block.number, "block");
        assertEq(v.timestamp, block.timestamp, "timestamp");
        assertTrue(v.preview.eligible, "eligible");
        assertEq(v.preview.usdCharge, 1234e8, "the RiskModule's charge");
        rm.setPledgePreview(false, bytes4(keccak256("BelowMinPledge()")), 5e8);
        v = lens.previewPledge(bob, MARKET_ID, _key(9));
        assertFalse(v.preview.eligible, "refused");
        assertEq(v.preview.reason, bytes4(keccak256("BelowMinPledge()")), "reason unchanged");
    }

    // ─── previewWithdraw ───

    // TEST-247 verifies: REQ-LENS-049
    function test_TEST_247_withdrawExampleAtTheBoundary() public {
        _borrow(aliceProxy, 8000e18);
        WithdrawPreview memory v = lens.previewWithdraw(alice, MARKET_ID, _key(1), 5000e6);
        assertEq(v.units, 5000e6, "units");
        assertEq(v.healthFactorAfter, 1e18, "HF 1.00");
        assertTrue(v.allowed, "allowed at exactly 1.00");
        v = lens.previewWithdraw(alice, MARKET_ID, _key(1), 5001e6);
        assertEq(v.healthFactorAfter, 0.9998e18, "HF 0.9998");
        assertFalse(v.allowed, "below 1.00");
        vm.prank(aliceProxy);
        IAaveV4Spoke(aave.cdpSpoke).withdraw(vtReserveId, 5000e6, aliceProxy);
        assertEq(_hf(aliceProxy), 1e18, "the Aave withdrawal lands at the previewed health factor");
    }

    // TEST-247 verifies: REQ-LENS-049
    function test_TEST_247_withdrawWholeRecordWithoutDebt() public {
        WithdrawPreview memory v = lens.previewWithdraw(alice, MARKET_ID, _key(1), 0);
        assertEq(v.units, 10_000e6, "units 0 means the whole record");
        assertEq(v.healthFactorAfter, type(uint256).max, "no debt");
        assertTrue(v.allowed, "a debt-free withdrawal is open");
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.MintPathSuspect);
        assertTrue(lens.previewWithdraw(alice, MARKET_ID, _key(1), 0).allowed, "in every pause state");
    }

    // TEST-247 verifies: REQ-LENS-049, SPEC-BACK-011
    function test_TEST_247_withdrawWholeRecordUsesReconciledUnits() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.8e8);
        uint256 seized = _seizeAndKeep(aliceProxy, 3000e18);
        WithdrawPreview memory v = lens.previewWithdraw(alice, MARKET_ID, _key(1), 0);
        assertEq(v.units, 10_000e6 - seized, "credited units after reconciliation");
        assertFalse(v.allowed, "with debt the whole record cannot leave");
        assertFalse(lens.previewWithdraw(alice, MARKET_ID, _key(1), 10_000e6 - seized + 1).allowed, "above it");
    }

    // TEST-247 verifies: REQ-LENS-049, REQ-ADAPTER-038, Q-398
    function test_TEST_247_withdrawGates() public {
        _borrow(aliceProxy, 4000e18);
        assertTrue(_allowed(1000e6), "HF stays high");
        rm.setGate(aliceProxy, false, false, PauseState.None);
        assertFalse(_allowed(1000e6), "withdraw-with-debt gate closed");
        rm.setGate(aliceProxy, true, false, PauseState.Paused);
        assertFalse(_allowed(1000e6), "Paused");
        rm.setGate(aliceProxy, true, false, PauseState.None);
        store.setHardHealthFloor(MARKET_ID, 3.7e18);
        assertFalse(_allowed(1000e6), "HF 4.0 falls to 3.6, below the market's 3.7 hard floor");
        store.setHardHealthFloor(MARKET_ID, 0);
        assertTrue(_allowed(1000e6), "floor off");
    }

    // TEST-247 verifies: REQ-LENS-049, SPEC-CF-005, Q-253
    function test_TEST_247_withdrawCountsRescueExclusion() public {
        riskModule.setRescue(true);
        _open(alice, aliceProxy, 2, 10_000e6);
        _borrow(aliceProxy, 8000e18);
        WithdrawPreview memory v = lens.previewWithdraw(alice, MARKET_ID, _key(1), 5000e6);
        assertEq(v.healthFactorAfter, 3e18, "Aave counts the rescue record: 24,000 / 8,000");
        assertTrue(v.allowed, "without the rescue units: 8,000 / 8,000 = 1.00");
        v = lens.previewWithdraw(alice, MARKET_ID, _key(1), 5001e6);
        assertGt(v.healthFactorAfter, 2.99e18, "Aave's HF is still near 3");
        assertFalse(v.allowed, "the rescue-excluded health factor falls below 1.00");
    }

    // TEST-247 verifies: REQ-LENS-049
    function test_TEST_247_withdrawOtherRecordOrNoRecord() public {
        _open(bob, bobProxy, 2, 1000e6);
        assertFalse(lens.previewWithdraw(alice, MARKET_ID, _key(2), 100e6).allowed, "another account's record");
        assertFalse(lens.previewWithdraw(alice, MARKET_ID, _key(77), 100e6).allowed, "no record");
        assertEq(lens.previewWithdraw(alice, MARKET_ID, _key(77), 0).units, 0, "no record: nothing to withdraw");
    }

    // ─── helpers ───

    function _assertBoundary(
        uint256 p
    ) internal {
        _setVtPrice(int256(p));
        assertGe(_hf(aliceProxy), 1e18, "at the liquidation price Aave's HF >= 1.00");
        _setVtPrice(int256(p - 1));
        assertLt(_hf(aliceProxy), 1e18, "one unit below it the account is liquidatable");
    }

    function _rate(
        uint256 assetId
    ) internal view returns (uint256 r) {
        (bool ok, bytes memory data) =
            aave.hub.staticcall(abi.encodeWithSignature("getAssetDrawnRate(uint256)", assetId));
        require(ok, "rate");
        r = abi.decode(data, (uint256));
    }

    function _allowed(
        uint256 units
    ) internal view returns (bool) {
        return lens.previewWithdraw(alice, MARKET_ID, _key(1), units).allowed;
    }
}
