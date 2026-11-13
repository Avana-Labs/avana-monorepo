// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationViews} from "../../src/custody/collateralization/ICollateralizationViews.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {RepayWithCollateralParams} from "../../src/policy/aave-adapter/types/RepayWithCollateralParams.sol";
import {AdapterSwapFixture} from "../utils/fixtures/AdapterSwapFixture.sol";

interface IBorrowableSwitch {
    function updateBorrowable(
        address spoke,
        uint256 reserveId,
        bool borrowable
    ) external;
}

/// @title AaveAdapterLPVaultSwapDeleverageIntegrationTest
/// @notice `repayWithCollateral` through the real AaveAdapter and the real LPVaultSwap on the real local Aave V4: the
/// session both sides hash, the borrower's bound on what it is paid, the debt mark after a full deleverage, and a debt
/// reserve whose new borrowing Aave turned off.
/// forge-config: default.isolate = false
contract AaveAdapterLPVaultSwapDeleverageIntegrationTest is AdapterSwapFixture {
    bytes32 internal key;
    address internal proxy;

    function setUp() public override {
        super.setUp();
        // Alice: 10,000 vault tokens ($20,000) against 10,000 GHO.
        (key, proxy) = _pledgeAs(alice, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 10_000e18);
    }

    function _params(
        uint128 units,
        uint256[] memory mins
    ) internal view returns (RepayWithCollateralParams memory p) {
        p = _rwc(MARKET_ID, key, units, debtReserveId);
        p.minAmounts = mins;
    }

    function _rwcAsAlice(
        RepayWithCollateralParams memory p
    ) internal returns (uint256 repaid, uint256 out) {
        vm.prank(alice);
        (repaid, out) = adapterC.repayWithCollateral(p);
    }

    // TEST-239 verifies: REQ-ADAPTER-080, REQ-SWAP-106
    /// @notice An empty `minAmounts` (no unwind minimum) runs end to end: the Adapter's session binds one zero per
    /// market token, the array LPVaultSwap passes to `deleverageRelease`, so the release step matches the session.
    function test_TEST_239_emptyMinAmountsMatchesTheSession() public {
        uint128 units = 1_500_000_000;
        _setLegs(units, 0);
        uint256 debtBefore = _debtOf(proxy, debtReserveId);
        (uint256 repaid, uint256 out) = _rwcAsAlice(_params(units, new uint256[](0)));
        assertGt(repaid, 0, "repaid");
        assertEq(_debtOf(proxy, debtReserveId), debtBefore - repaid, "debt fell by the repayment");
        assertEq(_sharesOf(proxy, vtReserveId), UNITS - units, "shares fell by units");
        assertEq(debt.balanceOf(alice), 10_000e18 + out, "leftover paid to the wallet");
        assertFalse(lock.isLocked(), "lock released");
    }

    // TEST-239 verifies: REQ-ADAPTER-080, REQ-SWAP-106
    /// @notice The same call with explicit zero minimums behaves identically (the two arrays hash the same).
    function test_TEST_239_explicitZeroMinimumsEqualEmpty() public {
        uint128 units = 1_500_000_000;
        _setLegs(units, 0);
        uint256 snap = vm.snapshotState();
        (uint256 r1, uint256 o1) = _rwcAsAlice(_params(units, new uint256[](0)));
        vm.revertToState(snap);
        (uint256 r2, uint256 o2) = _rwcAsAlice(_params(units, new uint256[](2)));
        assertEq(r1, r2, "same repayment");
        assertEq(o1, o2, "same leftover");
    }

    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-091
    /// @notice `minAssetOut` bounds what a sandwiched leg can take: with each leg filled 90 bps below par (inside the
    /// 100 bps allowance, so no leg minimum binds) the leftover is lower, a minimum one wei above it reverts
    /// `AssetOutBelowMinimum`, and a minimum equal to it passes.
    function test_TEST_239_minAssetOutStopsASandwichedLeg() public {
        uint128 units = 7_000_000_000; // $14,000 of units against 10,000 GHO: a leftover remains
        _setLegs(units, 0);
        uint256 snap = vm.snapshotState();
        (, uint256 fair) = _rwcAsAlice(_params(units, new uint256[](0)));
        vm.revertToState(snap);
        _setLegs(units, 90);
        snap = vm.snapshotState();
        (, uint256 sandwiched) = _rwcAsAlice(_params(units, new uint256[](0)));
        vm.revertToState(snap);
        assertLt(sandwiched, fair, "the sandwich came out of the leftover");
        RepayWithCollateralParams memory p = _params(units, new uint256[](0));
        p.minAssetOut = sandwiched + 1;
        vm.expectRevert(
            abi.encodeWithSelector(IAaveAdapterErrors.AssetOutBelowMinimum.selector, sandwiched, sandwiched + 1)
        );
        vm.prank(alice);
        adapterC.repayWithCollateral(p);
        p.minAssetOut = sandwiched;
        (, uint256 out) = _rwcAsAlice(p);
        assertEq(out, sandwiched, "a minimum equal to the leftover passes");
    }

    // TEST-272 verifies: REQ-COLL-040, REQ-ADAPTER-080
    /// @notice A repay with collateral that repays the last debt clears the account's indebted mark, so the market reads
    /// debt-free for `closeMarket` with no keeper `refreshDebtMark`.
    function test_TEST_272_fullDeleverageClearsTheDebtMark() public {
        ICollateralizationViews views = ICollateralizationViews(address(coll));
        assertFalse(views.getMarketDebtFree(vt), "marked by the borrow");
        uint128 units = 7_000_000_000;
        _setLegs(units, 0);
        _rwcAsAlice(_params(units, new uint256[](0)));
        assertEq(_borrowCountOf(proxy), 0, "no borrow left");
        assertTrue(views.getMarketDebtFree(vt), "mark cleared in the same call");
    }

    // TEST-272 verifies: REQ-COLL-040
    /// @notice A partial deleverage leaves the mark set: debt remains.
    function test_TEST_272_partialDeleverageKeepsTheDebtMark() public {
        uint128 units = 1_500_000_000;
        _setLegs(units, 0);
        _rwcAsAlice(_params(units, new uint256[](0)));
        assertGt(_borrowCountOf(proxy), 0, "debt remains");
        assertFalse(ICollateralizationViews(address(coll)).getMarketDebtFree(vt), "still marked");
    }

    // TEST-239 verifies: REQ-SWAP-087, REQ-SWAP-095, REQ-SWAP-003
    /// @notice Aave turning off new borrowing of the debt reserve does not stop a repay with collateral of it.
    function test_TEST_239_deleverageRunsWithBorrowingOff() public {
        vm.prank(aaveDao);
        IBorrowableSwitch(aave.spokeConfigurator).updateBorrowable(aave.cdpSpoke, debtReserveId, false);
        uint128 units = 1_500_000_000;
        _setLegs(units, 0);
        (uint256 repaid,) = _rwcAsAlice(_params(units, new uint256[](0)));
        assertGt(repaid, 0, "repaid with borrowing off");
    }
}
