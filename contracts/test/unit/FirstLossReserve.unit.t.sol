// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {FirstLossReserve} from "../../src/FirstLossReserve.sol";
import {IFirstLossReserve} from "../../src/interfaces/IFirstLossReserve.sol";
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

    /// @notice Bug hunted: shares minted for tokens that never reached the Hub. If the asset under-delivers on
    /// transferFrom (a fee on transfer, or a token upgraded to one), `add` would credit the reserve with Hub
    /// liquidity it did not bring. Here the transfer reports success and moves nothing.
    function test_fund_revertsWhenTheHubReceivesLessThanTheAmount() public {
        gho.mint(address(this), 1000e18);
        gho.approve(address(avanaLayer), 1000e18);
        uint256 before = avanaLayer.fundedBalance();
        vm.mockCall(address(gho), abi.encodeWithSelector(gho.transferFrom.selector), abi.encode(true));
        vm.expectRevert(abi.encodeWithSelector(IFirstLossReserve.TransferAmountMismatch.selector, 1000e18, 0));
        avanaLayer.fund(1000e18);
        vm.clearMockedCalls();
        assertEq(avanaLayer.fundedBalance(), before);
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
        assertEq(_cover(avanaLayer, cdp, type(uint256).max), 100_000e18);
        assertEq(avanaLayer.fundedBalance(), 0);
        assertEq(_cover(daoOffset, cdp, type(uint256).max), 150_000e18);
        assertEq(_deficit(cdp), 50_000e18);
    }

    /// @notice Called first, the offset pays only the part beyond Avana's balance, so the split is the same in either
    /// order; it refuses while Avana's balance covers the whole deficit.
    function test_lossOrder_offsetFirstPaysOnlyBeyondAvana() public {
        _reportDeficit(ghoAssetId, cdp, 300_000e18);
        assertEq(_cover(daoOffset, cdp, type(uint256).max), 150_000e18);
        assertEq(_cover(avanaLayer, cdp, type(uint256).max), 100_000e18);
        assertEq(_deficit(cdp), 50_000e18);
    }

    function test_lossOrder_offsetRefusesWhileAvanaCoversTheWholeDeficit() public {
        _reportDeficit(ghoAssetId, cdp, 10e18);
        uint256 avanaBalance = avanaLayer.fundedBalance();
        vm.prank(coverageCaller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFirstLossReserve.FirstLossLayerNotExhausted.selector, address(avanaLayer), avanaBalance
            )
        );
        daoOffset.coverDeficit(cdp, type(uint256).max);
    }

    /// @notice Bug hunted: a griefer blocking the DAO offset. `fund` is open, so anyone can put one wei into the emptied
    /// Avana layer just before the offset's cover. The offset must still pay its part (one wei less), and the wei is
    /// Avana's to cover.
    function test_lossOrder_oneWeiInAvanaCannotBlockTheOffset() public {
        _reportDeficit(ghoAssetId, cdp, 240_000e18);
        assertEq(_cover(avanaLayer, cdp, type(uint256).max), 100_000e18);
        _fundLayer(avanaLayer, makeAddr("griefer"), 1);
        assertEq(_cover(daoOffset, cdp, type(uint256).max), 140_000e18 - 1);
        assertEq(_cover(avanaLayer, cdp, type(uint256).max), 1, "the wei is Avana's share");
        assertEq(_deficit(cdp), 0);
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

    /// @notice Bug hunted: the zero address allowed as a deficit reporter because the Hub's listing answer is the only
    /// guard. Even a Hub that reported address(0) as a listed Spoke must not get it allowed.
    function test_setAllowedSpoke_zeroAddressRefusedEvenIfTheHubListsIt() public {
        vm.mockCall(
            aave.hub,
            abi.encodeWithSignature("isSpokeListed(uint256,address)", ghoAssetId, address(0)),
            abi.encode(true)
        );
        vm.prank(aaveGovernanceExecutor);
        vm.expectRevert(IFirstLossReserve.ZeroAddress.selector);
        avanaLayer.setAllowedSpoke(address(0), true);
        assertFalse(avanaLayer.isAllowedSpoke(address(0)));
    }

    // ─── Withdrawal ───

    function test_withdraw_needsTheFourteenDaySchedule() public {
        bytes memory data = abi.encodeCall(IFirstLossReserve.withdraw, (1000e18, avanaLabs));
        IAccessManager manager = IAccessManager(aave.accessManager);
        bytes32 id = manager.hashOperation(aaveGovernanceExecutor, address(avanaLayer), data);
        vm.prank(aaveGovernanceExecutor);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, id));
        avanaLayer.withdraw(1000e18, avanaLabs);

        vm.prank(aaveGovernanceExecutor);
        manager.schedule(address(avanaLayer), data, 0);
        vm.warp(block.timestamp + 14 days - 1);
        vm.prank(aaveGovernanceExecutor);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, id));
        manager.execute(address(avanaLayer), data);

        vm.warp(block.timestamp + 1);
        vm.prank(aaveGovernanceExecutor);
        manager.execute(address(avanaLayer), data);
        assertEq(gho.balanceOf(avanaLabs), 1000e18);
    }

    /// @notice A scheduled withdrawal that takes the layer under its minimum raises the alert, so a withdrawal cannot
    /// drain the first-loss cover below the committed size without monitoring seeing it.
    function test_withdraw_belowMinimumRaisesTheAlert() public {
        uint256 min = avanaLayer.minimum();
        uint256 balance = avanaLayer.fundedBalance();
        bytes memory data = abi.encodeCall(IFirstLossReserve.withdraw, (balance - min + 1000e18, avanaLabs));
        IAccessManager manager = IAccessManager(aave.accessManager);
        vm.prank(aaveGovernanceExecutor);
        manager.schedule(address(avanaLayer), data, 0);
        vm.warp(block.timestamp + 14 days);
        vm.expectEmit(address(avanaLayer));
        emit IFirstLossReserve.BelowMinimum(min - 1000e18, min);
        vm.prank(aaveGovernanceExecutor);
        manager.execute(address(avanaLayer), data);
        assertTrue(avanaLayer.isBelowMinimum());
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

    /// @notice Bug hunted: a withdrawal from an emptied layer that succeeds with nothing to send. It would emit a
    /// zero Withdrawn and call the Hub's remove for 0; a scheduled withdrawal that finds the layer empty must fail.
    function test_withdraw_revertsOnceTheLayerIsEmpty() public {
        uint256 balance = avanaLayer.fundedBalance();
        bytes memory all = abi.encodeCall(IFirstLossReserve.withdraw, (balance, avanaLabs));
        bytes memory more = abi.encodeCall(IFirstLossReserve.withdraw, (1e18, avanaLabs));
        IAccessManager manager = IAccessManager(aave.accessManager);
        vm.startPrank(aaveGovernanceExecutor);
        manager.schedule(address(avanaLayer), all, 0);
        manager.schedule(address(avanaLayer), more, 0);
        vm.warp(block.timestamp + 14 days);
        manager.execute(address(avanaLayer), all);
        assertEq(avanaLayer.fundedBalance(), 0);
        vm.expectRevert(IFirstLossReserve.ZeroAmount.selector);
        manager.execute(address(avanaLayer), more);
        vm.stopPrank();
        assertEq(gho.balanceOf(avanaLabs), balance);
    }

    /// @notice Bug hunted: a withdrawal that strands the GHO. Sent to the layer itself or to the Hub, the Hub's remove
    /// would take the shares out of the funded balance and leave the GHO where no call can move it; sent to address(0)
    /// it is burned or lost. A zero amount would emit a Withdrawn for nothing. Each is refused, and the funded balance and
    /// the recipients' GHO stay as they were.
    function test_withdraw_refusesARecipientThatStrandsTheGhoAndAZeroAmount() public {
        uint256 funded = avanaLayer.fundedBalance();
        uint256 hubGho = gho.balanceOf(aave.hub);
        address[3] memory bad = [address(avanaLayer), aave.hub, address(0)];
        bytes memory zero = abi.encodeCall(IFirstLossReserve.withdraw, (0, avanaLabs));
        IAccessManager manager = IAccessManager(aave.accessManager);
        vm.startPrank(aaveGovernanceExecutor);
        manager.schedule(address(avanaLayer), zero, 0);
        for (uint256 i; i < bad.length; ++i) {
            manager.schedule(address(avanaLayer), abi.encodeCall(IFirstLossReserve.withdraw, (1e18, bad[i])), 0);
        }
        vm.warp(block.timestamp + 14 days);
        vm.expectRevert(IFirstLossReserve.ZeroAmount.selector);
        manager.execute(address(avanaLayer), zero);
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IFirstLossReserve.InvalidRecipient.selector, bad[i]));
            manager.execute(address(avanaLayer), abi.encodeCall(IFirstLossReserve.withdraw, (1e18, bad[i])));
        }
        vm.stopPrank();
        assertEq(avanaLayer.fundedBalance(), funded);
        assertEq(gho.balanceOf(address(avanaLayer)), 0);
        assertEq(gho.balanceOf(aave.hub), hubGho);
    }
}
