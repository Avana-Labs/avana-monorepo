// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {FirstLossReserve} from "../../src/coverage/first-loss-reserve/FirstLossReserve.sol";
import {IFirstLossReserve} from "../../src/coverage/first-loss-reserve/IFirstLossReserve.sol";
import {FirstLossReserveFixture} from "../utils/fixtures/FirstLossReserveFixture.sol";
import {MockDebtAsset} from "../utils/mocks/MockDebtAsset.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

/// @notice FirstLossReserve on the local Aave V4 Hub: funding, the loss order of the two layers, coverage of recorded
/// deficits only, and the 14-day withdrawal.
contract FirstLossReserveUnitTest is FirstLossReserveFixture {
    address internal cdp;

    function setUp() public {
        _deployLayers();
        cdp = aave.cdpSpoke;
    }

    // ─── Construction ───

    function test_constructor_bindsPair() public view {
        assertEq(avanaLayer.HUB(), aave.hub);
        assertEq(avanaLayer.ASSET(), address(gho));
        assertEq(avanaLayer.ASSET_ID(), ghoAssetId);
        assertEq(avanaLayer.FIRST_LOSS_LAYER(), address(0));
        assertEq(daoOffset.FIRST_LOSS_LAYER(), address(avanaLayer));
        assertEq(avanaLayer.WITHDRAWAL_DELAY(), 14 days);
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(IFirstLossReserve.ZeroAddress.selector);
        new FirstLossReserve(address(0), address(gho), ghoAssetId, aave.accessManager, address(0));
        vm.expectRevert(IFirstLossReserve.ZeroAddress.selector);
        new FirstLossReserve(aave.hub, address(gho), ghoAssetId, address(0), address(0));
    }

    function test_constructor_revertsOnWrongAsset() public {
        MockDebtAsset other = new MockDebtAsset("Other", "OTH", 18);
        vm.expectRevert(abi.encodeWithSelector(IFirstLossReserve.InvalidHubAsset.selector, ghoAssetId));
        new FirstLossReserve(aave.hub, address(other), ghoAssetId, aave.accessManager, address(0));
    }

    function test_constructor_revertsOnOffsetBehindOffset() public {
        vm.expectRevert(abi.encodeWithSelector(IFirstLossReserve.InvalidFirstLossLayer.selector, address(daoOffset)));
        new FirstLossReserve(aave.hub, address(gho), ghoAssetId, aave.accessManager, address(daoOffset));
    }

    // ─── Funding ───

    function test_fund_addsSharesOnTheHub() public {
        uint256 before = avanaLayer.fundedBalance();
        gho.mint(address(this), 1000e18);
        gho.approve(address(avanaLayer), 1000e18);
        vm.expectEmit(true, false, false, false, address(avanaLayer));
        emit IFirstLossReserve.Funded(address(this), 1000e18, 0, 0);
        uint256 shares = avanaLayer.fund(1000e18);
        assertGt(shares, 0);
        assertEq(avanaLayer.fundedBalance(), before + 1000e18);
        assertEq(gho.balanceOf(address(avanaLayer)), 0, "holds no tokens");
    }

    function test_fund_revertsOnZero() public {
        vm.expectRevert(IFirstLossReserve.ZeroAmount.selector);
        avanaLayer.fund(0);
    }

    // ─── Coverage ───

    function test_cover_payOnlyTheRecordedDeficit() public {
        _reportDeficit(ghoAssetId, cdp, 5200e18);
        uint256 before = avanaLayer.fundedBalance();
        uint256 covered = _cover(avanaLayer, cdp, type(uint256).max);
        assertEq(covered, 5200e18);
        assertEq(_deficit(cdp), 0);
        assertApproxEqAbs(before - avanaLayer.fundedBalance(), 5200e18, 1);
    }

    function test_cover_revertsWithoutDeficit() public {
        vm.prank(coverageCaller);
        vm.expectRevert(abi.encodeWithSelector(IFirstLossReserve.NothingToCover.selector, cdp));
        avanaLayer.coverDeficit(cdp, 1e18);
    }

    function test_cover_revertsForDisallowedSpoke() public {
        _reportDeficit(ghoAssetId, otherSpoke, 10e18);
        vm.prank(coverageCaller);
        vm.expectRevert(abi.encodeWithSelector(IFirstLossReserve.SpokeNotAllowed.selector, otherSpoke));
        avanaLayer.coverDeficit(otherSpoke, 10e18);
    }

    function test_cover_restricted() public {
        _reportDeficit(ghoAssetId, cdp, 10e18);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        avanaLayer.coverDeficit(cdp, 10e18);
    }

    function test_cover_emitsBelowMinimum() public {
        _reportDeficit(ghoAssetId, cdp, 5200e18);
        vm.expectEmit(false, false, false, false, address(avanaLayer));
        emit IFirstLossReserve.BelowMinimum(0, 0);
        _cover(avanaLayer, cdp, 5200e18);
        assertTrue(avanaLayer.isBelowMinimum());
    }

    /// @notice The ARFC example: a 300,000 GHO loss is covered 100,000 by Avana, then 150,000 by the DAO offset; 50,000
    /// stays recorded.
    function test_lossOrder_avanaThenOffsetThenResidual() public {
        _reportDeficit(ghoAssetId, cdp, 300_000e18);
        uint256 avanaBalance = avanaLayer.fundedBalance();
        vm.prank(coverageCaller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFirstLossReserve.FirstLossLayerNotExhausted.selector, address(avanaLayer), avanaBalance
            )
        );
        daoOffset.coverDeficit(cdp, type(uint256).max);

        assertEq(_cover(avanaLayer, cdp, type(uint256).max), 100_000e18);
        assertEq(avanaLayer.fundedBalance(), 0);
        assertEq(_cover(daoOffset, cdp, type(uint256).max), 150_000e18);
        assertEq(_deficit(cdp), 50_000e18);
    }

    function test_lossOrder_offsetPaysWhenAvanaLayerDeactivated() public {
        _reportDeficit(ghoAssetId, cdp, 130_000e18);
        _setActive(ghoAssetId, address(avanaLayer), false);
        uint256 avanaBefore = avanaLayer.fundedBalance();
        assertEq(_cover(daoOffset, cdp, type(uint256).max), 130_000e18);
        assertEq(avanaLayer.fundedBalance(), avanaBefore, "Avana layer untouched");
    }

    // ─── Admin ───

    function test_setAllowedSpoke_requiresListing() public {
        address stranger = makeAddr("stranger");
        vm.prank(aaveGovernanceExecutor);
        vm.expectRevert(abi.encodeWithSelector(IFirstLossReserve.SpokeNotListed.selector, stranger));
        avanaLayer.setAllowedSpoke(stranger, true);
        vm.prank(aaveGovernanceExecutor);
        avanaLayer.setAllowedSpoke(cdp, false);
        assertFalse(avanaLayer.isAllowedSpoke(cdp));
    }

    // ─── Withdrawal ───

    function test_withdraw_needsTheFourteenDaySchedule() public {
        bytes memory data = abi.encodeCall(IFirstLossReserve.withdraw, (1000e18, avanaLabs));
        IAccessManager manager = IAccessManager(aave.accessManager);
        vm.prank(aaveGovernanceExecutor);
        vm.expectRevert();
        avanaLayer.withdraw(1000e18, avanaLabs);

        vm.prank(aaveGovernanceExecutor);
        manager.schedule(address(avanaLayer), data, 0);
        vm.warp(block.timestamp + 14 days - 1);
        vm.prank(aaveGovernanceExecutor);
        vm.expectRevert();
        manager.execute(address(avanaLayer), data);

        vm.warp(block.timestamp + 1);
        vm.prank(aaveGovernanceExecutor);
        manager.execute(address(avanaLayer), data);
        assertEq(gho.balanceOf(avanaLabs), 1000e18);
    }

    function test_withdraw_blockedWhileDeficitOutstanding() public {
        _reportDeficit(ghoAssetId, cdp, 10e18);
        bytes memory data = abi.encodeCall(IFirstLossReserve.withdraw, (1000e18, avanaLabs));
        IAccessManager manager = IAccessManager(aave.accessManager);
        vm.prank(aaveGovernanceExecutor);
        manager.schedule(address(avanaLayer), data, 0);
        vm.warp(block.timestamp + 14 days);
        vm.prank(aaveGovernanceExecutor);
        vm.expectRevert(abi.encodeWithSelector(IFirstLossReserve.DeficitOutstanding.selector, cdp));
        manager.execute(address(avanaLayer), data);
    }
}
