// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaFirstLossReserve} from "../../src/coverage/first-loss-reserve/AvanaFirstLossReserve.sol";
import {IAvanaFirstLossReserve} from "../../src/coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {IAvanaFirstLossReserveAdmin} from "../../src/coverage/first-loss-reserve/IAvanaFirstLossReserveAdmin.sol";
import {IAvanaFirstLossReserveErrors} from "../../src/coverage/first-loss-reserve/IAvanaFirstLossReserveErrors.sol";
import {Withdrawal, WithdrawalStatus} from "../../src/coverage/first-loss-reserve/types/Withdrawal.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {
    AvanaFirstLossReserveFixture,
    CoverageHubSpokeConfig,
    ICoverageHubConfigurator
} from "../utils/fixtures/AvanaFirstLossReserveFixture.sol";
import {MockDebtAsset} from "../utils/mocks/MockDebtAsset.sol";
import {FeeOnTransferToken} from "../utils/mocks/hostile/FeeOnTransferToken.sol";
import {HookToken} from "../utils/mocks/hostile/HookToken.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title AvanaFirstLossReserveUnitTest
/// @notice The First-Loss Reserve on its own on the real local Aave V4 Hub (2.14): construction and registration,
/// `fund` from any funder straight to the Hub, the DAO's allowlist and minimum, the 14-day withdrawal lifecycle, the
/// views, the role map in the Aave DAO's AccessManager and the Hub calls it makes.
/// @dev TEST-293 is the First-Loss Reserve row proposed to 5.1 with this suite (funding, allowlist, minimum, withdrawal
/// delay and views); TEST-002, TEST-062, TEST-080 and TEST-177 are linked for the First-Loss Reserve side.
contract AvanaFirstLossReserveUnitTest is AvanaFirstLossReserveFixture {
    bytes4 internal constant HUB_SPOKE_HALTED = bytes4(keccak256("SpokeHalted()"));
    bytes4 internal constant HUB_SPOKE_NOT_ACTIVE = bytes4(keccak256("SpokeNotActive()"));
    bytes4 internal constant HUB_ADD_CAP_EXCEEDED = bytes4(keccak256("AddCapExceeded(uint256)"));
    bytes4 internal constant HUB_INSUFFICIENT_LIQUIDITY = bytes4(keccak256("InsufficientLiquidity(uint256)"));
    bytes4 internal constant HUB_INVALID_AMOUNT = bytes4(keccak256("InvalidAmount()"));

    address internal lpVaultSwap = makeAddr("lpVaultSwap");
    address internal recipient = makeAddr("daoRecipient");

    function setUp() public {
        _deployCoverage();
    }

    // ─── Construction and registration ───

    // TEST-002 verifies: REQ-FLR-007, REQ-FLR-039, REQ-FLR-008, INV-042, Q-142, Q-236
    // Sources: 5.1 TEST-002 (First-Loss Reserves), 3.1 step 5
    /// @notice Each instance is registered only on its own asset with `drawCap = 0`, its add cap, active and not
    /// halted, holds `HUB_DEFICIT_ELIMINATOR_ROLE`, and exposes its Hub, asset, asset ID and the 14-day delay.
    function test_TEST_002_firstLossReserveRegistration() public view {
        _assertRegistration(ghoCoverage, address(gho), ghoAssetId, usdcAssetId, ADD_CAP_GHO);
        _assertRegistration(usdcCoverage, address(usdc), usdcAssetId, ghoAssetId, ADD_CAP_USDC);
    }

    // TEST-293 verifies: REQ-FLR-008, REQ-FLR-003, Q-101, Q-167, Q-236
    /// @notice The constructor fails closed: zero addresses, an asset ID that is not the asset, a decimals mismatch
    /// and an unlisted ID revert.
    function test_TEST_293_constructorFailsClosed() public {
        address am = aave.accessManager;
        vm.expectRevert(IAvanaFirstLossReserveErrors.ZeroAddress.selector);
        new AvanaFirstLossReserve(address(0), address(gho), ghoAssetId, am, RESERVE_WITHDRAWAL_DELAY);
        vm.expectRevert(IAvanaFirstLossReserveErrors.ZeroAddress.selector);
        new AvanaFirstLossReserve(aave.hub, address(0), ghoAssetId, am, RESERVE_WITHDRAWAL_DELAY);
        vm.expectRevert(IAvanaFirstLossReserveErrors.ZeroAddress.selector);
        new AvanaFirstLossReserve(aave.hub, address(gho), ghoAssetId, address(0), RESERVE_WITHDRAWAL_DELAY);
        vm.expectRevert(abi.encodeWithSelector(IAvanaFirstLossReserveErrors.InvalidHubAsset.selector, usdcAssetId));
        new AvanaFirstLossReserve(aave.hub, address(gho), usdcAssetId, am, RESERVE_WITHDRAWAL_DELAY);
        vm.expectRevert(abi.encodeWithSelector(IAvanaFirstLossReserveErrors.InvalidHubAsset.selector, 99));
        new AvanaFirstLossReserve(aave.hub, address(gho), 99, am, RESERVE_WITHDRAWAL_DELAY);

        // A token listed with decimals other than its own.
        MockDebtAsset odd = new MockDebtAsset("Odd", "ODD", 6);
        vm.prank(aaveDao);
        uint256 oddId = ICoverageHubConfigurator(aave.hubConfigurator)
            .addAssetWithDecimals(aave.hub, address(odd), 18, aave.treasurySpoke, 0, aave.irStrategy, _irData());
        vm.expectRevert(abi.encodeWithSelector(IAvanaFirstLossReserveErrors.InvalidHubAsset.selector, oddId));
        new AvanaFirstLossReserve(aave.hub, address(odd), oddId, am, RESERVE_WITHDRAWAL_DELAY);
    }

    // TEST-293 verifies: REQ-FLR-008, SPEC-FLR-003, Q-167
    /// @notice Any delay other than `reserveWithdrawalDelay` (1,209,600 s) reverts `InvalidWithdrawalDelay`.
    function testFuzz_TEST_293_constructorRequiresFourteenDays(
        uint256 delay
    ) public {
        vm.assume(delay != RESERVE_WITHDRAWAL_DELAY);
        vm.expectRevert(abi.encodeWithSelector(IAvanaFirstLossReserveErrors.InvalidWithdrawalDelay.selector, delay));
        new AvanaFirstLossReserve(aave.hub, address(gho), ghoAssetId, aave.accessManager, delay);
    }

    // TEST-293 verifies: REQ-FLR-002, REQ-FLR-003, Q-101, Q-142
    /// @notice The only authority is the DAO's AccessManager: `setAuthority` from anyone else, the DAO admin
    /// included, reverts; only the AccessManager itself moves it.
    function test_TEST_293_authorityOnlyAccessManager() public {
        assertEq(ghoCoverage.authority(), aave.accessManager, "authority");
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, aaveDao));
        vm.prank(aaveDao);
        ghoCoverage.setAuthority(attacker);
        address next = makeAddr("nextManager");
        vm.etch(next, hex"00");
        vm.prank(aaveDao);
        IAccessManager(aave.accessManager).updateAuthority(address(ghoCoverage), next);
        assertEq(ghoCoverage.authority(), next, "moved by the AccessManager");
    }

    // ─── Funding ───

    // TEST-293 verifies: REQ-FLR-005, REQ-FLR-010, REQ-FLR-012, REQ-FLR-038, SPEC-FLR-002, Q-101, Q-142, Q-211
    // Sources: 2.14 REQ-FLR-038, MATH-ST-62
    /// @notice LPVaultSwap funds like anyone: exactly `R` moves from it to the Hub, the shares go to the Coverage
    /// Spoke, the funder keeps no allowance, tokens or claim, `ReserveFunded` names it, and the balance rises by `R`
    /// up to the Hub's floor.
    function test_TEST_293_fundMovesExactAmountToHub() public {
        uint256 r = 83.8e18;
        gho.mint(lpVaultSwap, r);
        uint256 hubBalance = gho.balanceOf(aave.hub);
        uint256 balanceBefore = ghoCoverage.fundedBalance();
        uint256 sharesBefore = ghoCoverage.fundedShares();
        vm.startPrank(lpVaultSwap);
        gho.approve(address(ghoCoverage), r);
        vm.expectEmit(aave.hub);
        emit IAaveV4Hub.Add(ghoAssetId, address(ghoCoverage), r, r);
        vm.expectEmit(address(ghoCoverage));
        emit IAvanaFirstLossReserve.ReserveFunded(lpVaultSwap, r, r, balanceBefore + r);
        uint256 shares = ghoCoverage.fund(r);
        vm.stopPrank();
        assertEq(shares, r, "shares at price 1");
        assertEq(gho.balanceOf(aave.hub), hubBalance + r, "hub received exactly r");
        assertEq(gho.balanceOf(lpVaultSwap), 0, "funder sent exactly r");
        assertEq(gho.allowance(lpVaultSwap, address(ghoCoverage)), 0, "no allowance left");
        assertEq(gho.balanceOf(address(ghoCoverage)), 0, "the First-Loss Reserve holds no tokens");
        assertEq(ghoCoverage.fundedShares(), sharesBefore + shares, "shares credited to the First-Loss Reserve");
        assertEq(hub.getSpokeAddedShares(ghoAssetId, lpVaultSwap), 0, "funder gets no claim");
        assertEq(ghoCoverage.totalFunded(), FIRST_LOSS_RESERVE_MINIMUM_GHO + r, "totalFunded");
    }

    // TEST-293 verifies: REQ-FLR-001, REQ-FLR-005, SPEC-FLR-002, Q-070, Q-101
    // Sources: 2.14 REQ-FLR-001
    /// @notice The First-Loss Reserve of an asset is that asset held as its First-Loss Reserve's added shares on the Hub,
    /// and nothing else: `fundedBalance()` and `fundedShares()` are the Hub's added assets and shares of the instance
    /// on `ASSET_ID`; tokens sent to the instance or to the Hub add nothing; neither instance holds shares of the
    /// other asset; and a coverage is paid by burning the instance's own shares, never another supplier's.
    /// @dev Kills: `fundedBalance` reading a token balance (of the First-Loss Reserve or of the Hub), another asset ID or
    /// another holder's shares instead of the Hub's added assets of `address(this)` on `ASSET_ID`.
    function test_TEST_293_reserveIsTheInstanceAddedSharesOnItsHub() public {
        _fund(ghoCoverage, gho, avanaLabs, 2500e18);
        uint256 balance = ghoCoverage.fundedBalance();
        assertEq(balance, hub.getSpokeAddedAssets(ghoAssetId, address(ghoCoverage)), "the Hub's added assets");
        assertEq(balance, FIRST_LOSS_RESERVE_MINIMUM_GHO + 2500e18, "everything funded");
        assertEq(ghoCoverage.fundedShares(), hub.getSpokeAddedShares(ghoAssetId, address(ghoCoverage)), "shares");
        gho.mint(address(ghoCoverage), 777e18);
        gho.mint(aave.hub, 333e18);
        assertEq(ghoCoverage.fundedBalance(), balance, "tokens sent outside fund are not reserve");
        assertEq(hub.getSpokeAddedShares(usdcAssetId, address(ghoCoverage)), 0, "no USDC shares in the GHO reserve");
        assertEq(hub.getSpokeAddedShares(ghoAssetId, address(usdcCoverage)), 0, "no GHO shares in the USDC reserve");

        _reportDeficit(ghoAssetId, aave.cdpSpoke, 1000e18);
        uint256 shares = ghoCoverage.fundedShares();
        uint256 lendShares = hub.getSpokeAddedShares(ghoAssetId, aave.lendSpoke);
        vm.prank(coverageCaller);
        (uint256 burned, uint256 covered) = ghoCoverage.coverDeficit(aave.cdpSpoke, type(uint256).max);
        assertEq(covered, 1000e18, "covered");
        assertEq(hub.getSpokeAddedShares(ghoAssetId, address(ghoCoverage)), shares - burned, "paid from its shares");
        assertEq(hub.getSpokeAddedShares(ghoAssetId, aave.lendSpoke), lendShares, "no other supplier pays");
        assertEq(gho.balanceOf(address(ghoCoverage)), 777e18, "the donation stays untouched");
    }

    // TEST-293 verifies: REQ-FLR-010, REQ-FLR-015, SPEC-FLR-002, Q-142
    /// @notice With supply interest accrued (A > S), `fund(x)` raises `fundedBalance` by between `x − 2` and `x + 1`
    /// and the shares minted are `floor(x (S + 1e6) / (A + 1e6))`; the reserve's own shares earn the yield.
    function testFuzz_TEST_293_fundAtAccruedPrice(
        uint256 x,
        uint256 elapsed
    ) public {
        x = bound(x, 1e12, 500_000e18);
        elapsed = bound(elapsed, 1 days, 730 days);
        _draw(ghoAssetId, aave.cdpSpoke, 1_000_000e18);
        uint256 before = ghoCoverage.fundedBalance();
        vm.warp(block.timestamp + elapsed);
        uint256 accrued = ghoCoverage.fundedBalance();
        assertGt(accrued, before, "yield accrues to the reserve");
        uint256 s = hub.getAddedShares(ghoAssetId) + 1e6;
        uint256 a = hub.getAddedAssets(ghoAssetId) + 1e6;
        uint256 shares = _fund(ghoCoverage, gho, avanaLabs, x);
        assertEq(shares, x * s / a, "shares rounded down");
        uint256 afterFund = ghoCoverage.fundedBalance();
        assertGe(afterFund + 2, accrued + x, "rise at least x - 2");
        assertLe(afterFund, accrued + x + 1, "rise at most x + 1");
    }

    // TEST-177 verifies: REQ-FLR-010, Q-217
    /// @notice A zero reserve funding is a zero user input: it reverts `ZeroAmount` and calls neither the token nor
    /// the Hub.
    function test_TEST_177_zeroFundReverts() public {
        vm.expectCall(address(gho), abi.encodeWithSelector(gho.transferFrom.selector), 0);
        vm.expectCall(aave.hub, abi.encodeWithSelector(IAaveV4Hub.add.selector), 0);
        vm.expectRevert(IAvanaFirstLossReserveErrors.ZeroAmount.selector);
        vm.prank(avanaLabs);
        ghoCoverage.fund(0);
    }

    // TEST-293 verifies: REQ-FLR-005, REQ-FLR-010, Q-101, Q-124
    /// @notice A fee-on-transfer asset delivers less than `amount` to the Hub, so `fund` reverts
    /// `TransferAmountMismatch` even where a donation to the Hub would let `Hub.add` pass.
    function test_TEST_293_fundRefusesShortDelivery() public {
        FeeOnTransferToken fee = new FeeOnTransferToken(100);
        (AvanaFirstLossReserve cs,) = _listedInstance(address(fee), 18);
        fee.mint(aave.hub, 10e18); // donation the Hub does not account
        fee.mint(avanaLabs, 100e18);
        vm.startPrank(avanaLabs);
        fee.approve(address(cs), 100e18);
        vm.expectRevert(
            abi.encodeWithSelector(IAvanaFirstLossReserveErrors.TransferAmountMismatch.selector, 100e18, 99e18)
        );
        cs.fund(100e18);
        vm.stopPrank();
    }

    // TEST-293 verifies: REQ-FLR-006, Q-148
    /// @notice A token that re-enters `fund` from its `transferFrom` is refused by the guard; the outer call completes
    /// once.
    function test_TEST_293_fundIsNonReentrant() public {
        HookToken hook = new HookToken();
        (AvanaFirstLossReserve cs,) = _listedInstance(address(hook), 18);
        hook.mint(address(this), 20e18);
        hook.approve(address(cs), 20e18);
        hook.arm(address(cs), abi.encodeCall(IAvanaFirstLossReserve.fund, (1e18)));
        cs.fund(10e18);
        assertTrue(hook.hookCalled(), "hook ran");
        assertFalse(hook.hookSucceeded(), "re-entry refused");
        assertEq(
            bytes4(hook.hookReturn()),
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
            "reentrancy guard error"
        );
        assertEq(cs.totalFunded(), 10e18, "one funding recorded");
    }

    // TEST-293 verifies: REQ-FLR-010, REQ-FLR-035, REQ-FLR-036, REQ-FLR-037, Q-140, Q-142
    /// @notice The Hub's own checks stop `fund`: halted (`SpokeHalted`), deactivated (`SpokeNotActive`) and above
    /// `firstLossReserveAddCap` (`AddCapExceeded`).
    function test_TEST_293_fundStoppedByHubChecks() public {
        gho.mint(avanaLabs, 2_000_000e18);
        vm.prank(avanaLabs);
        gho.approve(address(ghoCoverage), type(uint256).max);

        _setHalted(ghoAssetId, address(ghoCoverage), true);
        vm.expectRevert(HUB_SPOKE_HALTED);
        vm.prank(avanaLabs);
        ghoCoverage.fund(1e18);
        _setHalted(ghoAssetId, address(ghoCoverage), false);

        uint256 room = uint256(ADD_CAP_GHO) * 1e18 - ghoCoverage.fundedBalance();
        vm.expectRevert(abi.encodeWithSelector(HUB_ADD_CAP_EXCEEDED, uint256(ADD_CAP_GHO)));
        vm.prank(avanaLabs);
        ghoCoverage.fund(room + 1);
        vm.prank(avanaLabs);
        ghoCoverage.fund(room);

        _setActive(ghoAssetId, address(ghoCoverage), false);
        vm.expectRevert(HUB_SPOKE_NOT_ACTIVE);
        vm.prank(avanaLabs);
        ghoCoverage.fund(1e18);
    }

    // TEST-080 verifies: REQ-FLR-005, Q-119, Q-124
    /// @notice Dust donated to the First-Loss Reserve or to the Hub is not counted: `fundedBalance()` and `totalFunded`
    /// are unchanged, the donation stays where it was sent (no sweep exists), and funding and coverage still work.
    function testFuzz_TEST_080_donationsNotCounted(
        uint256 dust
    ) public {
        dust = bound(dust, 1, 1e6);
        uint256 balance = ghoCoverage.fundedBalance();
        gho.mint(address(ghoCoverage), dust);
        gho.mint(aave.hub, dust);
        assertEq(ghoCoverage.fundedBalance(), balance, "donations not counted");
        assertEq(ghoCoverage.totalFunded(), FIRST_LOSS_RESERVE_MINIMUM_GHO, "totalFunded");
        _fund(ghoCoverage, gho, avanaLabs, 1e18);
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 1e18);
        vm.prank(coverageCaller);
        (, uint256 covered) = ghoCoverage.coverDeficit(aave.cdpSpoke, 1e18);
        assertEq(covered, 1e18, "coverage unaffected");
        assertEq(gho.balanceOf(address(ghoCoverage)), dust, "donation untouched");
    }

    // ─── Allowlist and minimum (RESERVE_ADMIN_ROLE) ───

    // TEST-293 verifies: REQ-FLR-016, REQ-FLR-017, Q-190, Q-286
    /// @notice Adding needs a non-zero Spoke listed on this asset of this Hub; removal of any address takes effect at
    /// once; each call emits `BorrowSpokeAllowlistUpdated`.
    function test_TEST_293_allowlistRules() public {
        vm.startPrank(aaveGovernanceExecutor);
        vm.expectRevert(IAvanaFirstLossReserveErrors.ZeroAddress.selector);
        ghoCoverage.setAllowedBorrowSpoke(address(0), true);
        vm.expectRevert(abi.encodeWithSelector(IAvanaFirstLossReserveErrors.BorrowSpokeNotListed.selector, attacker));
        ghoCoverage.setAllowedBorrowSpoke(attacker, true);
        vm.expectEmit(address(ghoCoverage));
        emit IAvanaFirstLossReserveAdmin.BorrowSpokeAllowlistUpdated(otherSpoke, true);
        ghoCoverage.setAllowedBorrowSpoke(otherSpoke, true);
        assertTrue(ghoCoverage.allowedBorrowSpoke(otherSpoke), "added");
        vm.expectEmit(address(ghoCoverage));
        emit IAvanaFirstLossReserveAdmin.BorrowSpokeAllowlistUpdated(otherSpoke, false);
        ghoCoverage.setAllowedBorrowSpoke(otherSpoke, false);
        assertFalse(ghoCoverage.allowedBorrowSpoke(otherSpoke), "removed");
        ghoCoverage.setAllowedBorrowSpoke(attacker, false);
        vm.stopPrank();

        // A Spoke listed on the Hub's GHO asset only cannot be added to the USDC instance.
        address ghoOnly = makeAddr("ghoOnlySpoke");
        CoverageHubSpokeConfig memory config = _config(0, DRAW_CAP);
        vm.prank(aaveDao);
        ICoverageHubConfigurator(aave.hubConfigurator).addSpoke(aave.hub, ghoOnly, ghoAssetId, config);
        vm.expectRevert(abi.encodeWithSelector(IAvanaFirstLossReserveErrors.BorrowSpokeNotListed.selector, ghoOnly));
        vm.prank(aaveGovernanceExecutor);
        usdcCoverage.setAllowedBorrowSpoke(ghoOnly, true);
    }

    // TEST-293 verifies: REQ-FLR-013, REQ-FLR-014, Q-241, Q-391, Q-399
    /// @notice The DAO sets any minimum, with `FirstLossReserveMinimumUpdated(old, new)`; `isBelowMinimum()` is
    /// `fundedBalance() < minimum` at the boundary; the minimum blocks neither funding nor coverage.
    function test_TEST_293_minimumIsAlertOnly() public {
        uint256 balance = ghoCoverage.fundedBalance();
        vm.expectEmit(address(ghoCoverage));
        emit IAvanaFirstLossReserveAdmin.FirstLossReserveMinimumUpdated(FIRST_LOSS_RESERVE_MINIMUM_GHO, balance);
        vm.prank(aaveGovernanceExecutor);
        ghoCoverage.setFirstLossReserveMinimum(balance);
        assertEq(ghoCoverage.firstLossReserveMinimum(), balance, "minimum");
        assertFalse(ghoCoverage.isBelowMinimum(), "equal is not below");
        vm.prank(aaveGovernanceExecutor);
        ghoCoverage.setFirstLossReserveMinimum(balance + 1);
        assertTrue(ghoCoverage.isBelowMinimum(), "one wei short is below");
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 10e18);
        vm.prank(coverageCaller);
        ghoCoverage.coverDeficit(aave.cdpSpoke, 10e18);
        _fund(ghoCoverage, gho, avanaLabs, 1e18);
        vm.prank(aaveGovernanceExecutor);
        ghoCoverage.setFirstLossReserveMinimum(0);
        assertFalse(ghoCoverage.isBelowMinimum(), "zero minimum");
    }

    // TEST-293 verifies: REQ-FLR-014, Q-241
    /// @notice `isBelowMinimum()` and the balance views keep answering while the instance is halted or deactivated.
    function test_TEST_293_viewsNeverRevert() public {
        _setHalted(ghoAssetId, address(ghoCoverage), true);
        assertFalse(ghoCoverage.isBelowMinimum(), "halted");
        _setActive(ghoAssetId, address(ghoCoverage), false);
        assertFalse(ghoCoverage.isBelowMinimum(), "inactive");
        assertEq(ghoCoverage.fundedBalance(), hub.getSpokeAddedAssets(ghoAssetId, address(ghoCoverage)), "balance");
        assertEq(ghoCoverage.fundedShares(), hub.getSpokeAddedShares(ghoAssetId, address(ghoCoverage)), "shares");
    }

    // ─── Withdrawals (RESERVE_ADMIN_ROLE, 14 days) ───

    // TEST-293 verifies: REQ-FLR-023, REQ-FLR-025, REQ-FLR-033, SPEC-FLR-003, Q-101, Q-167
    // Sources: 2.14 SPEC-FLR-003 example
    /// @notice A request at 1,780,000,000 is executable from 1,781,209,600: one second earlier reverts
    /// `WithdrawalNotReady`; at that second it withdraws from the Hub straight to the recipient.
    function test_TEST_293_withdrawalWaitsFourteenDays() public {
        vm.warp(1_780_000_000);
        _fund(ghoCoverage, gho, avanaLabs, 50_000e18);
        vm.expectEmit(address(ghoCoverage));
        emit IAvanaFirstLossReserve.WithdrawalRequested(1, 50_000e18, recipient, 1_781_209_600);
        uint256 id = _request(50_000e18, recipient);
        assertEq(id, 1, "first id");
        assertEq(ghoCoverage.nextWithdrawalId(), 2, "next id");
        Withdrawal memory w = ghoCoverage.getWithdrawal(id);
        assertEq(w.amount, 50_000e18, "amount");
        assertEq(w.to, recipient, "to");
        assertEq(w.executableAt, 1_781_209_600, "executableAt");
        assertEq(uint8(w.status), uint8(WithdrawalStatus.Pending), "pending");

        vm.warp(1_781_209_599);
        vm.expectRevert(
            abi.encodeWithSelector(IAvanaFirstLossReserveErrors.WithdrawalNotReady.selector, id, uint64(1_781_209_600))
        );
        _execute(id);

        vm.warp(1_781_209_600);
        uint256 balance = ghoCoverage.fundedBalance();
        uint256 expectedShares = _sharesUp(ghoAssetId, 50_000e18);
        vm.expectEmit(address(ghoCoverage));
        emit IAvanaFirstLossReserve.WithdrawalExecuted(id, 50_000e18, expectedShares, recipient, balance - 50_000e18);
        uint256 withdrawn = _execute(id);
        assertEq(withdrawn, 50_000e18, "withdrawn");
        assertEq(gho.balanceOf(recipient), 50_000e18, "paid from the Hub");
        assertEq(gho.balanceOf(address(ghoCoverage)), 0, "nothing held");
        assertEq(ghoCoverage.totalWithdrawn(), 50_000e18, "totalWithdrawn");
        assertEq(uint8(ghoCoverage.getWithdrawal(id).status), uint8(WithdrawalStatus.Executed), "executed");
        vm.expectRevert(abi.encodeWithSelector(IAvanaFirstLossReserveErrors.WithdrawalNotPending.selector, id));
        _execute(id);
    }

    // TEST-293 verifies: REQ-FLR-014, REQ-FLR-025, SPEC-FLR-003, Q-101, Q-102
    // Sources: MATH-ST-61
    /// @notice A request made before a coverage call executes for what remains: `min(request, fundedBalance())`,
    /// burning `ceil(withdrawn (S + 1e6) / (A + 1e6))` shares, and emits `ReserveBelowMinimum` when it leaves the
    /// balance below the minimum.
    function test_TEST_293_withdrawalCappedAtBalanceAndAlerts() public {
        uint256 id = _request(150_000e18, recipient);
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 40_000e18);
        vm.prank(coverageCaller);
        ghoCoverage.coverDeficit(aave.cdpSpoke, 40_000e18);
        vm.warp(block.timestamp + RESERVE_WITHDRAWAL_DELAY);
        uint256 balance = ghoCoverage.fundedBalance();
        vm.expectEmit(address(ghoCoverage));
        emit IAvanaFirstLossReserve.ReserveBelowMinimum(0, FIRST_LOSS_RESERVE_MINIMUM_GHO);
        uint256 withdrawn = _execute(id);
        assertEq(withdrawn, balance, "capped at the funded balance");
        assertEq(ghoCoverage.fundedShares(), 0, "all shares burned, none beyond");
        assertEq(gho.balanceOf(recipient), balance, "recipient");
    }

    // TEST-293 verifies: REQ-FLR-025, REQ-FLR-034, REQ-FLR-035, SPEC-FLR-003, Q-095, Q-140
    /// @notice Hub refusals leave the request Pending: `InsufficientLiquidity` while the asset is drawn,
    /// `SpokeHalted` while the instance is halted, and `InvalidAmount` with nothing funded; it executes once they
    /// clear.
    function test_TEST_293_hubRefusalsKeepRequestPending() public {
        uint256 id = _request(100_000e18, recipient);
        vm.warp(block.timestamp + RESERVE_WITHDRAWAL_DELAY);
        uint256 liquidity = hub.getAssetLiquidity(ghoAssetId);
        _draw(ghoAssetId, aave.cdpSpoke, 1_000_000e18);
        _draw(ghoAssetId, otherSpoke, liquidity - 1_000_000e18 - 1);
        vm.expectRevert(abi.encodeWithSelector(HUB_INSUFFICIENT_LIQUIDITY, uint256(1)));
        _execute(id);
        assertEq(uint8(ghoCoverage.getWithdrawal(id).status), uint8(WithdrawalStatus.Pending), "still pending");

        _supplyCreditLine(gho, ghoAssetId, 200_000e18);
        _setHalted(ghoAssetId, address(ghoCoverage), true);
        vm.expectRevert(HUB_SPOKE_HALTED);
        _execute(id);
        _setHalted(ghoAssetId, address(ghoCoverage), false);
        assertEq(_execute(id), FIRST_LOSS_RESERVE_MINIMUM_GHO, "executes after the refusals clear");

        AvanaFirstLossReserve empty =
            _deployAvanaFirstLossReserve(address(gho), ghoAssetId, ADD_CAP_GHO, "EmptyCoverage");
        vm.prank(aaveGovernanceExecutor);
        uint256 emptyId = empty.requestWithdrawal(1e18, recipient);
        vm.warp(block.timestamp + RESERVE_WITHDRAWAL_DELAY);
        vm.expectRevert(HUB_INVALID_AMOUNT);
        vm.prank(aaveGovernanceExecutor);
        empty.executeWithdrawal(emptyId);
        assertEq(uint8(empty.getWithdrawal(emptyId).status), uint8(WithdrawalStatus.Pending), "pending");
    }

    // TEST-293 verifies: REQ-FLR-023, REQ-FLR-024, REQ-FLR-033, Q-101
    /// @notice Request inputs and cancellation: zero amount and invalid recipients revert; a Pending request cancels
    /// before or after `executableAt`; cancelled, executed and unknown requests revert `WithdrawalNotPending`.
    function test_TEST_293_requestAndCancelRules() public {
        vm.startPrank(aaveGovernanceExecutor);
        vm.expectRevert(IAvanaFirstLossReserveErrors.ZeroAmount.selector);
        ghoCoverage.requestWithdrawal(0, recipient);
        address[3] memory bad = [address(0), address(ghoCoverage), aave.hub];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IAvanaFirstLossReserveErrors.InvalidRecipient.selector, bad[i]));
            ghoCoverage.requestWithdrawal(1e18, bad[i]);
        }
        uint256 a = ghoCoverage.requestWithdrawal(1e18, recipient);
        uint256 b = ghoCoverage.requestWithdrawal(2e18, recipient);
        assertEq(b, a + 1, "ids increment");
        vm.expectEmit(address(ghoCoverage));
        emit IAvanaFirstLossReserve.WithdrawalCancelled(a);
        ghoCoverage.cancelWithdrawal(a);
        assertEq(uint8(ghoCoverage.getWithdrawal(a).status), uint8(WithdrawalStatus.Cancelled), "cancelled");
        vm.expectRevert(abi.encodeWithSelector(IAvanaFirstLossReserveErrors.WithdrawalNotPending.selector, a));
        ghoCoverage.cancelWithdrawal(a);
        vm.expectRevert(abi.encodeWithSelector(IAvanaFirstLossReserveErrors.WithdrawalNotPending.selector, a));
        ghoCoverage.executeWithdrawal(a);
        vm.expectRevert(abi.encodeWithSelector(IAvanaFirstLossReserveErrors.WithdrawalNotPending.selector, 77));
        ghoCoverage.cancelWithdrawal(77);
        assertEq(uint8(ghoCoverage.getWithdrawal(77).status), uint8(WithdrawalStatus.None), "unknown id");
        vm.warp(block.timestamp + RESERVE_WITHDRAWAL_DELAY + 1);
        ghoCoverage.cancelWithdrawal(b);
        vm.stopPrank();
        assertEq(ghoCoverage.totalWithdrawn(), 0, "nothing withdrawn");
    }

    // TEST-293 verifies: REQ-FLR-025, SPEC-FLR-003, Q-101
    /// @notice For any request and any time past the delay, execution withdraws `min(request, fundedBalance())`
    /// and burns at most the shares held.
    function testFuzz_TEST_293_withdrawnIsMinOfRequestAndBalance(
        uint256 amount,
        uint256 lost,
        uint256 extra
    ) public {
        amount = bound(amount, 1, 1_000_000e18);
        lost = bound(lost, 0, 150_000e18);
        extra = bound(extra, 0, 365 days);
        uint256 id = _request(amount, recipient);
        if (lost > 0) {
            _reportDeficit(ghoAssetId, aave.cdpSpoke, lost);
            vm.prank(coverageCaller);
            ghoCoverage.coverDeficit(aave.cdpSpoke, lost);
        }
        vm.warp(block.timestamp + RESERVE_WITHDRAWAL_DELAY + extra);
        if (hub.getSpokeDeficitRay(ghoAssetId, aave.cdpSpoke) != 0) {
            // A deficit larger than the reserve stays open after coverage and blocks the withdrawal until the DAO
            // removes the Spoke from the allowlist (REQ-FLR-026).
            vm.expectRevert(
                abi.encodeWithSelector(IAvanaFirstLossReserveErrors.DeficitOutstanding.selector, aave.cdpSpoke)
            );
            _execute(id);
            vm.prank(aaveGovernanceExecutor);
            ghoCoverage.setAllowedBorrowSpoke(aave.cdpSpoke, false);
        }
        uint256 balance = ghoCoverage.fundedBalance();
        uint256 sharesHeld = ghoCoverage.fundedShares();
        uint256 expected = amount < balance ? amount : balance;
        uint256 expectedBurn = _sharesUp(ghoAssetId, expected);
        if (balance == 0) {
            vm.expectRevert(HUB_INVALID_AMOUNT);
            _execute(id);
            return;
        }
        uint256 withdrawn = _execute(id);
        assertEq(withdrawn, expected, "min(request, balance)");
        assertLe(expectedBurn, sharesHeld, "burn within shares held");
        assertEq(sharesHeld - ghoCoverage.fundedShares(), expectedBurn, "shares rounded up");
        assertEq(gho.balanceOf(recipient), expected, "recipient paid");
    }

    // ─── Role map and Hub calls ───

    // TEST-062 verifies: REQ-FLR-002, REQ-FLR-016, REQ-FLR-023, REQ-FLR-024, REQ-FLR-025, REQ-FLR-032, Q-101, Q-142
    /// @notice Every privileged selector checks its role in the DAO's AccessManager: the admin functions refuse the
    /// coverage caller, Avana Labs, the governance multisig and a stranger; `coverDeficit` refuses the admin; `fund`
    /// and the views are public.
    function test_TEST_062_roleMap() public {
        address[4] memory outsiders = [coverageCaller, avanaLabs, governanceMultisig, attacker];
        bytes[5] memory calls = [
            abi.encodeCall(IAvanaFirstLossReserveAdmin.setAllowedBorrowSpoke, (otherSpoke, true)),
            abi.encodeCall(IAvanaFirstLossReserveAdmin.setFirstLossReserveMinimum, (1)),
            abi.encodeCall(IAvanaFirstLossReserveAdmin.requestWithdrawal, (1e18, recipient)),
            abi.encodeCall(IAvanaFirstLossReserveAdmin.cancelWithdrawal, (1)),
            abi.encodeCall(IAvanaFirstLossReserveAdmin.executeWithdrawal, (1))
        ];
        for (uint256 i = 0; i < outsiders.length; ++i) {
            for (uint256 j = 0; j < calls.length; ++j) {
                vm.prank(outsiders[i]);
                (bool ok, bytes memory ret) = address(ghoCoverage).call(calls[j]);
                assertFalse(ok, "admin call accepted");
                assertEq(
                    ret,
                    abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsiders[i]),
                    "unauthorized"
                );
            }
        }
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, aaveGovernanceExecutor)
        );
        vm.prank(aaveGovernanceExecutor);
        ghoCoverage.coverDeficit(aave.cdpSpoke, 1e18);
        _fund(ghoCoverage, gho, attacker, 1e18);
    }

    // TEST-293 verifies: REQ-FLR-004, REQ-FLR-040, INV-042, INV-071, Q-236
    /// @notice The only state-changing Hub calls are `add` from `fund`, `eliminateDeficit` from `coverDeficit` and
    /// `remove` from `executeWithdrawal`, each on the instance's own asset ID; `draw`, `restore`, `reportDeficit`,
    /// `transferShares`, `payFeeShares`, `refreshPremium`, `sweep` and `reclaim` are never called.
    function test_TEST_293_hubCallsOnOwnAssetOnly() public {
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 1e18);
        uint256 id = _request(1e18, recipient);
        _expectNoForbiddenHubCall();
        vm.expectCall(aave.hub, abi.encodeWithSelector(IAaveV4Hub.add.selector, ghoAssetId), 1);
        vm.expectCall(
            aave.hub, abi.encodeWithSelector(IAaveV4Hub.eliminateDeficit.selector, ghoAssetId, 1e18, aave.cdpSpoke), 1
        );
        vm.expectCall(aave.hub, abi.encodeWithSelector(IAaveV4Hub.remove.selector, ghoAssetId, 1e18, recipient), 1);

        _fund(ghoCoverage, gho, avanaLabs, 1e18);
        vm.prank(coverageCaller);
        ghoCoverage.coverDeficit(aave.cdpSpoke, 1e18);
        vm.warp(block.timestamp + RESERVE_WITHDRAWAL_DELAY);
        _execute(id);
    }

    // ─── Helpers ───

    function _request(
        uint256 amount,
        address to
    ) internal returns (uint256 id) {
        vm.prank(aaveGovernanceExecutor);
        id = ghoCoverage.requestWithdrawal(amount, to);
    }

    function _execute(
        uint256 id
    ) internal returns (uint256 withdrawn) {
        vm.prank(aaveGovernanceExecutor);
        withdrawn = ghoCoverage.executeWithdrawal(id);
    }

    function _expectNoForbiddenHubCall() internal {
        string[8] memory sigs = [
            "draw(uint256,uint256,address)",
            "restore(uint256,uint256,(int256,int256,uint256))",
            "reportDeficit(uint256,uint256,(int256,int256,uint256))",
            "transferShares(uint256,uint256,address)",
            "payFeeShares(uint256,uint256)",
            "refreshPremium(uint256,(int256,int256,uint256))",
            "sweep(uint256,uint256)",
            "reclaim(uint256,uint256)"
        ];
        for (uint256 i = 0; i < sigs.length; ++i) {
            vm.expectCall(aave.hub, abi.encodeWithSignature(sigs[i]), 0);
        }
    }

    function _irData() internal pure returns (bytes memory) {
        return abi.encode(uint16(9000), uint32(0), uint32(400), uint32(6000));
    }

    function _config(
        uint40 addCap,
        uint40 drawCap
    ) internal view returns (CoverageHubSpokeConfig memory) {
        return CoverageHubSpokeConfig(addCap, drawCap, hub.MAX_RISK_PREMIUM_THRESHOLD(), true, false);
    }

    // ─── Review fixes (2026-11-10) ───

    // TEST-293 verifies: REQ-FLR-025, REQ-FLR-026, REQ-FLR-045, SPEC-FLR-003, Q-101
    // Sources: AvanaFirstLossReserve review 2026-11-10 (L-1)
    /// @notice A withdrawal requested before a deficit cannot drain the reserve while that deficit is open: execution
    /// reverts `DeficitOutstanding(spoke)` and the request stays Pending; a deficit on a Spoke that is not allowlisted
    /// does not block it; once the deficit is covered the request executes.
    function test_TEST_293_withdrawalWaitsForCoverage() public {
        vm.prank(aaveGovernanceExecutor);
        uint256 id = ghoCoverage.requestWithdrawal(10_000e18, recipient);
        vm.warp(block.timestamp + RESERVE_WITHDRAWAL_DELAY - 1 days);
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 50_000e18);
        _reportDeficit(ghoAssetId, otherSpoke, 1000e18);
        vm.warp(block.timestamp + 1 days);
        vm.prank(aaveGovernanceExecutor);
        vm.expectRevert(abi.encodeWithSelector(IAvanaFirstLossReserveErrors.DeficitOutstanding.selector, aave.cdpSpoke));
        ghoCoverage.executeWithdrawal(id);
        assertEq(uint8(ghoCoverage.getWithdrawal(id).status), uint8(WithdrawalStatus.Pending), "still Pending");
        vm.prank(coverageCaller);
        ghoCoverage.coverDeficit(aave.cdpSpoke, type(uint256).max);
        assertEq(hub.getSpokeDeficitRay(ghoAssetId, aave.cdpSpoke), 0, "covered");
        vm.prank(aaveGovernanceExecutor);
        assertEq(ghoCoverage.executeWithdrawal(id), 10_000e18, "executes after coverage");
        assertGt(hub.getSpokeDeficitRay(ghoAssetId, otherSpoke), 0, "other Spoke's deficit never blocked it");
    }

    // TEST-293 verifies: REQ-FLR-026
    /// @notice Removing a Spoke from the allowlist lifts its block: the DAO decides, and the decision is on-chain.
    function test_TEST_293_allowlistRemovalLiftsTheBlock() public {
        vm.prank(aaveGovernanceExecutor);
        uint256 id = ghoCoverage.requestWithdrawal(1e18, recipient);
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 1e18);
        vm.warp(block.timestamp + RESERVE_WITHDRAWAL_DELAY);
        vm.startPrank(aaveGovernanceExecutor);
        vm.expectRevert(abi.encodeWithSelector(IAvanaFirstLossReserveErrors.DeficitOutstanding.selector, aave.cdpSpoke));
        ghoCoverage.executeWithdrawal(id);
        ghoCoverage.setAllowedBorrowSpoke(aave.cdpSpoke, false);
        assertEq(ghoCoverage.executeWithdrawal(id), 1e18, "executes");
        vm.stopPrank();
    }

    // TEST-293 verifies: REQ-FLR-010, REQ-FLR-037, REQ-FLR-038, Q-211
    // Sources: AvanaFirstLossReserve review 2026-11-10 (M-1)
    /// @notice Once yield lifts the share price above 1, a `fund` below one share's value mints no share and the Hub
    /// reverts `InvalidShares`, which is why LPVaultSwap's `settlePending` carries such an amount to the next settlement
    /// instead of funding it; a fund of at least one share's value succeeds.
    function test_TEST_293_dustFundBelowOneShareReverts() public {
        _draw(ghoAssetId, aave.cdpSpoke, 1_000_000e18);
        vm.warp(block.timestamp + 30 days);
        assertGt(hub.getAddedAssets(ghoAssetId), hub.getAddedShares(ghoAssetId), "share price above 1");
        gho.mint(lpVaultSwap, 2);
        vm.startPrank(lpVaultSwap);
        gho.approve(address(ghoCoverage), 2);
        vm.expectRevert(bytes4(keccak256("InvalidShares()")));
        ghoCoverage.fund(1);
        assertGt(ghoCoverage.fund(2), 0, "one share's value funds");
        vm.stopPrank();
    }

    // TEST-293 verifies: REQ-FLR-007, REQ-FLR-011, REQ-FLR-037, Q-211
    // Sources: AvanaFirstLossReserve review 2026-11-10 (M-1)
    /// @notice Yield alone can fill a finite add cap and stop every later `fund`; with the listed `addCap = MAX` the
    /// same yield never does.
    function test_TEST_293_yieldFillsFiniteCapButNotMax() public {
        uint256 room = uint256(ADD_CAP_GHO) * 1e18 - ghoCoverage.fundedBalance();
        _fund(ghoCoverage, gho, avanaLabs, room);
        _draw(ghoAssetId, aave.cdpSpoke, 1_500_000e18);
        vm.warp(block.timestamp + 1 days);
        assertGt(ghoCoverage.fundedBalance(), uint256(ADD_CAP_GHO) * 1e18, "yield above the cap");
        gho.mint(lpVaultSwap, 2e18);
        vm.prank(lpVaultSwap);
        gho.approve(address(ghoCoverage), 2e18);
        vm.prank(lpVaultSwap);
        vm.expectRevert(abi.encodeWithSelector(HUB_ADD_CAP_EXCEEDED, uint256(ADD_CAP_GHO)));
        ghoCoverage.fund(1e18);
        uint40 maxCap = hub.MAX_ALLOWED_SPOKE_CAP();
        vm.prank(aaveDao);
        ICoverageHubConfigurator(aave.hubConfigurator)
            .updateSpokeAddCap(aave.hub, ghoAssetId, address(ghoCoverage), maxCap);
        vm.prank(lpVaultSwap);
        assertGt(ghoCoverage.fund(1e18), 0, "funds at addCap = MAX");
    }

    // TEST-293 verifies: SPEC-FLR-002, REQ-FLR-015
    // Sources: AvanaFirstLossReserve review 2026-11-10 (Info-2)
    /// @notice With yield the reporting totals are not a balance: after a year of interest the reserve covers more than
    /// was ever funded, so `totalFunded − totalCovered − totalWithdrawn` is negative and a reader must treat it as
    /// signed.
    function test_TEST_293_totalsAreSignedUnderYield() public {
        _draw(ghoAssetId, aave.cdpSpoke, 1_500_000e18);
        vm.warp(block.timestamp + 365 days);
        uint256 balance = ghoCoverage.fundedBalance();
        assertGt(balance, ghoCoverage.totalFunded(), "yield earned");
        _reportDeficit(ghoAssetId, otherSpoke, balance + 1e18);
        vm.prank(aaveGovernanceExecutor);
        ghoCoverage.setAllowedBorrowSpoke(otherSpoke, true);
        vm.prank(coverageCaller);
        ghoCoverage.coverDeficit(otherSpoke, type(uint256).max);
        assertGt(ghoCoverage.totalCovered(), ghoCoverage.totalFunded(), "covered more than funded");
    }

    // TEST-293 verifies: REQ-FLR-002, REQ-FLR-044, Q-101
    /// @notice The DAO's AccessManager governs every role: a `COVERAGE_ROLE` grant with an execution delay makes a
    /// direct `coverDeficit` revert until the call is scheduled and the delay has passed, and a revoked holder is
    /// refused at once.
    function test_TEST_293_accessManagerDelaysAndRevocation() public {
        address delayed = makeAddr("delayedGuardian");
        IAccessManager manager = IAccessManager(aave.accessManager);
        vm.prank(aaveDao);
        manager.grantRole(COVERAGE_ROLE, delayed, 1 days);
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 1e18);
        bytes memory data = abi.encodeCall(IAvanaFirstLossReserve.coverDeficit, (aave.cdpSpoke, 1e18));
        bytes32 operation = manager.hashOperation(delayed, address(ghoCoverage), data);
        vm.prank(delayed);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, operation));
        ghoCoverage.coverDeficit(aave.cdpSpoke, 1e18);
        vm.prank(delayed);
        manager.schedule(address(ghoCoverage), data, 0);
        vm.warp(block.timestamp + 1 days);
        vm.prank(delayed);
        (, uint256 covered) = ghoCoverage.coverDeficit(aave.cdpSpoke, 1e18);
        assertEq(covered, 1e18, "covered after the delay");
        vm.prank(aaveDao);
        manager.revokeRole(COVERAGE_ROLE, coverageCaller);
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 1e18);
        vm.prank(coverageCaller);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, coverageCaller));
        ghoCoverage.coverDeficit(aave.cdpSpoke, 1e18);
    }

    /// @notice Lists `token` on the Hub and deploys a registered, funded-to-nothing First-Loss Reserve for it.
    function _listedInstance(
        address token,
        uint8 decimals
    ) internal returns (AvanaFirstLossReserve cs, uint256 assetId) {
        assetId = _listDebtAsset(token, decimals);
        cs = _deployAvanaFirstLossReserve(token, assetId, ADD_CAP_GHO, "HostileAssetCoverage");
    }

    function _assertRegistration(
        AvanaFirstLossReserve cs,
        address asset,
        uint256 assetId,
        uint256 otherAssetId,
        uint40 addCap
    ) internal view {
        assertEq(cs.HUB(), aave.hub, "HUB");
        assertEq(cs.ASSET(), asset, "ASSET");
        assertEq(cs.ASSET_ID(), assetId, "ASSET_ID");
        assertEq(cs.RESERVE_WITHDRAWAL_DELAY(), RESERVE_WITHDRAWAL_DELAY, "delay");
        IAaveV4Hub.SpokeConfig memory c = hub.getSpokeConfig(assetId, address(cs));
        assertEq(c.drawCap, 0, "drawCap 0");
        assertEq(c.addCap, addCap, "addCap");
        assertTrue(c.active && !c.halted, "active, not halted");
        assertFalse(hub.isSpokeListed(otherAssetId, address(cs)), "not on another asset");
        (bool member,) = IAccessManager(aave.accessManager).hasRole(HUB_DEFICIT_ELIMINATOR_ROLE, address(cs));
        assertTrue(member, "deficit eliminator");
    }
}
