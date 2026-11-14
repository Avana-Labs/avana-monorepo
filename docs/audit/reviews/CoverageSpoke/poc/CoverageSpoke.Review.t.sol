// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CoverageSpoke} from "../../src/coverage/coverage-spoke/CoverageSpoke.sol";
import {ICoverageSpokeErrors} from "../../src/coverage/coverage-spoke/ICoverageSpokeErrors.sol";
import {CoverageSpokeFixture} from "../utils/fixtures/CoverageSpokeFixture.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

/// Review PoCs (scratch only).
contract CoverageSpokeReviewTest is CoverageSpokeFixture {
    bytes4 internal constant HUB_INVALID_SHARES = bytes4(keccak256("InvalidShares()"));
    bytes4 internal constant HUB_ADD_CAP_EXCEEDED = bytes4(keccak256("AddCapExceeded(uint256)"));
    bytes4 internal constant HUB_INSUFFICIENT_LIQUIDITY = bytes4(keccak256("InsufficientLiquidity(uint256)"));
    bytes4 internal constant HUB_INVALID_AMOUNT = bytes4(keccak256("InvalidAmount()"));

    address internal lpVaultSwap = makeAddr("lpVaultSwap");
    address internal griefer = makeAddr("griefer");
    address internal recipient = makeAddr("daoRecipient");

    function setUp() public {
        _deployCoverage();
    }

    /// Once yield lifts the share price above 1, a dust `fund(R)` mints 0 shares and the Hub reverts
    /// `InvalidShares`; LPVaultSwap.settlePending with a dust R > 0 would revert with it.
    function test_PoC_dustFundRevertsInvalidShares() public {
        _draw(ghoAssetId, aave.cdpSpoke, 1_000_000e18);
        vm.warp(block.timestamp + 30 days);
        assertGt(hub.getAddedAssets(ghoAssetId), hub.getAddedShares(ghoAssetId), "A > S");
        gho.mint(lpVaultSwap, 1);
        vm.startPrank(lpVaultSwap);
        gho.approve(address(ghoCoverage), 1);
        vm.expectRevert(HUB_INVALID_SHARES);
        ghoCoverage.fund(1);
        vm.stopPrank();
    }

    /// Yield alone pushes the reserve past `firstLossReserveAddCap`: every later `fund` (Avana top-up or
    /// LPVaultSwap pending-settlement proceeds) reverts `AddCapExceeded` with no new funding.
    function test_PoC_yieldFillsAddCapBlocksFund() public {
        uint256 room = uint256(ADD_CAP_GHO) * 1e18 - ghoCoverage.fundedBalance();
        _fund(ghoCoverage, gho, griefer, room); // anyone may fill it; here the cap is reached exactly
        _draw(ghoAssetId, aave.cdpSpoke, 1_500_000e18);
        vm.warp(block.timestamp + 1 days);
        assertGt(ghoCoverage.fundedBalance(), uint256(ADD_CAP_GHO) * 1e18, "yield above addCap");
        gho.mint(lpVaultSwap, 1e18);
        vm.startPrank(lpVaultSwap);
        gho.approve(address(ghoCoverage), 1e18);
        vm.expectRevert(abi.encodeWithSelector(HUB_ADD_CAP_EXCEEDED, uint256(ADD_CAP_GHO)));
        ghoCoverage.fund(1e18);
        vm.stopPrank();
    }

    /// A withdrawal requested before a deficit executes after it, while the deficit is still uncovered:
    /// nothing on-chain orders coverage before withdrawal, and the reserve leaves at a price that still counts
    /// the uncovered deficit as an asset.
    function test_PoC_withdrawalDrainsReserveWithUncoveredDeficit() public {
        uint256 bal = ghoCoverage.fundedBalance();
        vm.prank(aaveGovernanceExecutor);
        uint256 id = ghoCoverage.requestWithdrawal(type(uint256).max, recipient);
        vm.warp(block.timestamp + RESERVE_WITHDRAWAL_DELAY - 1 days);
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 50_000e18);
        vm.warp(block.timestamp + 1 days); // still inside the 72-hour coverage window
        vm.prank(aaveGovernanceExecutor);
        uint256 withdrawn = ghoCoverage.executeWithdrawal(id);
        assertEq(withdrawn, bal, "whole reserve left");
        assertEq(hub.getSpokeDeficitRay(ghoAssetId, aave.cdpSpoke), 50_000e18 * 1e27, "deficit uncovered");
        vm.prank(coverageCaller);
        vm.expectRevert(abi.encodeWithSelector(ICoverageSpokeErrors.NothingToCover.selector, aave.cdpSpoke));
        ghoCoverage.coverDeficit(aave.cdpSpoke, type(uint256).max);
    }

    /// At full utilization the reserve's withdrawal reverts as a whole (no partial min with liquidity).
    function test_PoC_withdrawalBlockedByUtilization() public {
        uint256 liq = gho.balanceOf(aave.hub);
        _draw(ghoAssetId, aave.cdpSpoke, 1_900_000e18);
        _draw(ghoAssetId, otherSpoke, liq - 1_900_000e18 - 1e18);
        vm.prank(aaveGovernanceExecutor);
        uint256 id = ghoCoverage.requestWithdrawal(10e18, recipient);
        vm.warp(block.timestamp + RESERVE_WITHDRAWAL_DELAY);
        vm.prank(aaveGovernanceExecutor);
        vm.expectRevert(abi.encodeWithSelector(HUB_INSUFFICIENT_LIQUIDITY, 1e18));
        ghoCoverage.executeWithdrawal(id);
    }

    /// Full coverage leaves sub-unit dust shares that no path can ever spend or withdraw
    /// (fundedBalance()==0 -> NothingToCover / InvalidAmount).
    function test_PoC_dustSharesStrandedAfterFullCoverage() public {
        _draw(ghoAssetId, aave.cdpSpoke, 1_000_000e18);
        vm.warp(block.timestamp + 365 days);
        uint256 bal = ghoCoverage.fundedBalance();
        _reportDeficit(ghoAssetId, otherSpoke, bal + 1e18);
        vm.prank(aaveGovernanceExecutor);
        ghoCoverage.setAllowedBorrowSpoke(otherSpoke, true);
        vm.prank(coverageCaller);
        (, uint256 covered) = ghoCoverage.coverDeficit(otherSpoke, type(uint256).max);
        assertEq(covered, bal);
        assertEq(ghoCoverage.fundedBalance(), 0, "balance 0");
        emit log_named_uint("stranded shares", ghoCoverage.fundedShares());
        vm.prank(aaveGovernanceExecutor);
        uint256 id = ghoCoverage.requestWithdrawal(1, recipient);
        vm.warp(block.timestamp + RESERVE_WITHDRAWAL_DELAY);
        vm.prank(aaveGovernanceExecutor);
        vm.expectRevert(HUB_INVALID_AMOUNT);
        ghoCoverage.executeWithdrawal(id);
    }

    /// The DAO's AccessManager can open coverDeficit to everyone (PUBLIC_ROLE) and retarget authority
    /// instantly; the 14-day delay is the only in-contract limit, and the same role cancels.
    function test_PoC_daoCanMakeCoveragePublicAndSwapAuthority() public {
        bytes4[] memory sel = new bytes4[](1);
        sel[0] = CoverageSpoke.coverDeficit.selector;
        IAccessManager manager = IAccessManager(aave.accessManager);
        vm.prank(aaveDao);
        manager.setTargetFunctionRole(address(ghoCoverage), sel, type(uint64).max);
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 1e18);
        vm.prank(griefer);
        ghoCoverage.coverDeficit(aave.cdpSpoke, 1e18);
        address newAuth = address(new FakeAuthority());
        vm.prank(aaveDao);
        manager.updateAuthority(address(ghoCoverage), newAuth);
        assertEq(ghoCoverage.authority(), newAuth);
        vm.prank(griefer);
        ghoCoverage.requestWithdrawal(1e18, griefer);
    }

    /// Totals vs. Hub value under yield: reporting totals diverge from fundedBalance.
    function testFuzz_PoC_netFundingVsBalance(uint256 x, uint256 d, uint256 elapsed) public {
        x = bound(x, 1e15, 500_000e18);
        d = bound(d, 1e9, 200_000e18);
        elapsed = bound(elapsed, 0, 365 days);
        _fund(ghoCoverage, gho, avanaLabs, x);
        _draw(ghoAssetId, aave.cdpSpoke, 500_000e18);
        vm.warp(block.timestamp + elapsed);
        _reportDeficit(ghoAssetId, otherSpoke, d);
        d = d; // keep
        vm.prank(aaveGovernanceExecutor);
        ghoCoverage.setAllowedBorrowSpoke(otherSpoke, true);
        vm.prank(coverageCaller);
        (, uint256 covered) = ghoCoverage.coverDeficit(otherSpoke, type(uint256).max);
        assertEq(covered, ghoCoverage.totalCovered(), "covered == totalCovered");
        // With yield, totalCovered can exceed totalFunded: the spec's net expression goes negative.
        if (elapsed == 0) {
            assertLe(ghoCoverage.fundedBalance() + ghoCoverage.totalCovered(), ghoCoverage.totalFunded(), "no-yield");
        }
        assertLe(hub.getSpokeDeficitRay(ghoAssetId, otherSpoke), d * 1e27);
    }
}

contract FakeAuthority {
    function canCall(address, address, bytes4) external pure returns (bool, uint32) {
        return (true, 0);
    }
}

contract CoverageSpokeReviewYieldTest is CoverageSpokeFixture {
    function setUp() public {
        _deployCoverage();
    }

    /// With yield, the reserve covers more than was ever funded: totalCovered > totalFunded, so the
    /// SPEC-FLR-002 identity `totalFunded - totalCovered - totalWithdrawn` underflows for any unsigned reader.
    function test_PoC_totalCoveredExceedsTotalFunded() public {
        _draw(ghoAssetId, aave.cdpSpoke, 1_500_000e18);
        vm.warp(block.timestamp + 365 days);
        uint256 bal = ghoCoverage.fundedBalance();
        _reportDeficit(ghoAssetId, otherSpoke, bal + 1e18);
        vm.prank(aaveGovernanceExecutor);
        ghoCoverage.setAllowedBorrowSpoke(otherSpoke, true);
        vm.prank(coverageCaller);
        ghoCoverage.coverDeficit(otherSpoke, type(uint256).max);
        assertGt(ghoCoverage.totalCovered(), ghoCoverage.totalFunded(), "covered > funded");
        emit log_named_uint("funded", ghoCoverage.totalFunded());
        emit log_named_uint("covered", ghoCoverage.totalCovered());
    }
}
