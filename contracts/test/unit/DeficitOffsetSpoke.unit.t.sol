// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICoverageSpoke} from "../../src/coverage/coverage-spoke/ICoverageSpoke.sol";
import {ICoverageSpokeErrors} from "../../src/coverage/coverage-spoke/ICoverageSpokeErrors.sol";
import {DeficitOffsetSpoke} from "../../src/coverage/deficit-offset-spoke/DeficitOffsetSpoke.sol";
import {IDeficitOffsetSpoke} from "../../src/coverage/deficit-offset-spoke/IDeficitOffsetSpoke.sol";
import {DeficitOffsetSpokeFixture} from "../utils/fixtures/DeficitOffsetSpokeFixture.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

/// @dev Views a constructor reads from its first-loss layer, each settable, to reach every mismatch branch.
contract FirstLossLayerViews {
    address public HUB;
    address public ASSET;
    uint256 public ASSET_ID;

    constructor(
        address hub,
        address asset,
        uint256 assetId
    ) {
        HUB = hub;
        ASSET = asset;
        ASSET_ID = assetId;
    }
}

/// @title DeficitOffsetSpokeUnitTest
/// @notice TEST-298 on the pinned Aave V4 release (real Hub, HubConfigurator and AccessManager): the DAO deficit offset
/// of a `(Hub, asset)` is a Coverage Spoke bound at deployment to that pair's Avana Umbrella; it eliminates a recorded
/// deficit only once the Avana Umbrella's funded balance is zero, each layer's funds are its own Hub position, and the
/// remainder beyond both layers stays recorded.
contract DeficitOffsetSpokeUnitTest is DeficitOffsetSpokeFixture {
    function setUp() public {
        _deployLayers();
    }

    function _deploy(
        address layer
    ) internal returns (DeficitOffsetSpoke) {
        return new DeficitOffsetSpoke(aave.hub, address(gho), ghoAssetId, aave.accessManager, 1_209_600, layer);
    }

    // ─── Construction ───

    // TEST-298 verifies: REQ-FLR-047, REQ-FLR-008, Q-410
    // Sources: 5.1 TEST-298
    /// @notice A zero first-loss layer reverts `ZeroAddress`; the Coverage Spoke constructor checks still apply.
    function test_TEST_298_constructorRejectsZeroLayerAndInheritsChecks() public {
        vm.expectRevert(ICoverageSpokeErrors.ZeroAddress.selector);
        _deploy(address(0));
        vm.expectRevert(abi.encodeWithSelector(ICoverageSpokeErrors.InvalidWithdrawalDelay.selector, 1));
        new DeficitOffsetSpoke(aave.hub, address(gho), ghoAssetId, aave.accessManager, 1, address(ghoCoverage));
        vm.expectRevert(ICoverageSpokeErrors.ZeroAddress.selector);
        new DeficitOffsetSpoke(
            address(0), address(gho), ghoAssetId, aave.accessManager, 1_209_600, address(ghoCoverage)
        );
        vm.expectRevert(abi.encodeWithSelector(ICoverageSpokeErrors.InvalidHubAsset.selector, usdcAssetId));
        new DeficitOffsetSpoke(aave.hub, address(gho), usdcAssetId, aave.accessManager, 1_209_600, address(ghoCoverage));
    }

    // TEST-298 verifies: REQ-FLR-047, REQ-FLR-040, Q-410
    /// @notice A layer of another asset, or a layer whose `HUB()`, `ASSET()` or `ASSET_ID()` alone differs, reverts
    /// `FirstLossLayerMismatch`; the matching layer deploys and is read back by `FIRST_LOSS_LAYER()`.
    function test_TEST_298_constructorRejectsMismatchedLayer() public {
        address[4] memory bad = [
            address(usdcCoverage),
            address(new FirstLossLayerViews(address(0xBEEF), address(gho), ghoAssetId)),
            address(new FirstLossLayerViews(aave.hub, address(usdc), ghoAssetId)),
            address(new FirstLossLayerViews(aave.hub, address(gho), ghoAssetId + 7))
        ];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IDeficitOffsetSpoke.FirstLossLayerMismatch.selector, bad[i]));
            _deploy(bad[i]);
        }
        DeficitOffsetSpoke ok = _deploy(address(ghoCoverage));
        assertEq(ok.FIRST_LOSS_LAYER(), address(ghoCoverage), "layer");
        assertEq(ok.HUB(), aave.hub, "hub");
        assertEq(ok.ASSET(), address(gho), "asset");
        assertEq(ok.ASSET_ID(), ghoAssetId, "asset id");
        assertEq(ok.RESERVE_WITHDRAWAL_DELAY(), 1_209_600, "delay");
        assertEq(ghoOffset.FIRST_LOSS_LAYER(), address(ghoCoverage), "fixture GHO layer");
        assertEq(usdcOffset.FIRST_LOSS_LAYER(), address(usdcCoverage), "fixture USDC layer");
    }

    // ─── Funding ───

    // TEST-298 verifies: REQ-FLR-046, REQ-FLR-049, REQ-FLR-010, DEF-024, Q-410
    /// @notice The DAO treasury's `fund` credits Hub shares to the offset only: the Avana Umbrella's shares, balance and
    /// totals do not move, and the offset's minimum holds `daoDeficitOffset`.
    function test_TEST_298_daoFundingIsItsOwnPosition() public {
        assertEq(ghoOffset.fundedBalance(), DAO_OFFSET_GHO, "offset funded to its size");
        assertEq(ghoOffset.firstLossReserveMinimum(), DAO_OFFSET_GHO, "minimum = daoDeficitOffset");
        assertEq(ghoOffset.totalFunded(), DAO_OFFSET_GHO, "offset totalFunded");
        assertEq(ghoCoverage.totalFunded(), FIRST_LOSS_RESERVE_MINIMUM_GHO, "Avana totalFunded");
        uint256 avanaShares = ghoCoverage.fundedShares();
        uint256 avanaBalance = ghoCoverage.fundedBalance();
        uint256 offsetShares = ghoOffset.fundedShares();

        gho.mint(daoTreasury, 20_000e18);
        vm.startPrank(daoTreasury);
        gho.approve(address(ghoOffset), 20_000e18);
        vm.expectEmit(true, false, false, true, address(ghoOffset));
        emit ICoverageSpoke.ReserveFunded(daoTreasury, 20_000e18, 20_000e18, DAO_OFFSET_GHO + 20_000e18);
        uint256 shares = ghoOffset.fund(20_000e18);
        vm.stopPrank();

        assertEq(shares, 20_000e18, "shares at price 1");
        assertEq(ghoOffset.fundedShares(), offsetShares + shares, "offset shares");
        assertEq(hub.getSpokeAddedShares(ghoAssetId, address(ghoOffset)), offsetShares + shares, "Hub position");
        assertEq(ghoCoverage.fundedShares(), avanaShares, "Avana shares unchanged");
        assertEq(ghoCoverage.fundedBalance(), avanaBalance, "Avana balance unchanged");
        assertFalse(ghoOffset.isBelowMinimum(), "above the offset size");
    }

    // ─── Loss order ───

    // TEST-298 verifies: REQ-FLR-048, REQ-FLR-050, INV-100, SPEC-FLR-006, DEF-F-011, ATTACK-199, Q-410
    /// @notice While the Avana Umbrella holds funds, the offset's `coverDeficit` reverts
    /// `FirstLossLayerNotExhausted(layer, balance)` and changes nothing: the deficit, both balances and the totals stay.
    function test_TEST_298_offsetRefusedWhileAvanaLayerFunded() public {
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 50_000e18);
        uint256 deficitRay = hub.getSpokeDeficitRay(ghoAssetId, aave.cdpSpoke);
        uint256 offsetShares = ghoOffset.fundedShares();
        vm.prank(coverageCaller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDeficitOffsetSpoke.FirstLossLayerNotExhausted.selector, address(ghoCoverage), 100_000e18
            )
        );
        ghoOffset.coverDeficit(aave.cdpSpoke, type(uint256).max);
        assertEq(hub.getSpokeDeficitRay(ghoAssetId, aave.cdpSpoke), deficitRay, "deficit unchanged");
        assertEq(ghoOffset.fundedShares(), offsetShares, "offset shares unchanged");
        assertEq(ghoOffset.totalCovered(), 0, "offset covered nothing");
        assertEq(ghoCoverage.fundedBalance(), 100_000e18, "Avana layer unchanged");
    }

    // TEST-298 verifies: REQ-FLR-048, REQ-FLR-049, REQ-FLR-027, REQ-FLR-031, SPEC-FLR-006, INV-100, DEF-024, DEF-007, DEF-F-004, Q-410
    /// @notice A 300,000 GHO deficit: the Avana Umbrella covers its 100,000, then the DAO offset its 150,000, each burning
    /// only its own shares (Hub `EliminateDeficit` names each as caller), and 50,000 GHO stays recorded.
    function test_TEST_298_avanaLayerThenDaoOffsetThenResidual() public {
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 300_000e18);
        uint256 offsetShares = ghoOffset.fundedShares();

        vm.expectEmit(true, true, true, true, aave.hub);
        emit EliminateDeficit(ghoAssetId, address(ghoCoverage), aave.cdpSpoke, 100_000e18, 100_000e18 * RAY);
        assertEq(_coverWith(ghoCoverage, aave.cdpSpoke, type(uint256).max), 100_000e18, "Avana layer covers 100,000");
        assertEq(ghoCoverage.fundedBalance(), 0, "Avana layer exhausted");
        assertEq(ghoCoverage.fundedShares(), 0, "no Avana share left");
        assertEq(ghoOffset.fundedShares(), offsetShares, "DAO shares untouched by the first layer");

        vm.expectEmit(true, true, true, true, aave.hub);
        emit EliminateDeficit(ghoAssetId, address(ghoOffset), aave.cdpSpoke, 150_000e18, 150_000e18 * RAY);
        vm.expectEmit(true, true, false, true, address(ghoOffset));
        emit ICoverageSpoke.DeficitCovered(
            aave.cdpSpoke, coverageCaller, 150_000e18, 150_000e18, 200_000e18 * RAY, 50_000e18 * RAY, 0
        );
        vm.expectEmit(false, false, false, true, address(ghoOffset));
        emit ICoverageSpoke.ReserveBelowMinimum(0, DAO_OFFSET_GHO);
        assertEq(_coverWith(ghoOffset, aave.cdpSpoke, type(uint256).max), 150_000e18, "DAO offset covers 150,000");

        assertEq(_deficitUnits(ghoAssetId, aave.cdpSpoke), 50_000e18, "residual 50,000 stays recorded");
        assertEq(ghoCoverage.totalCovered(), 100_000e18, "Avana totalCovered");
        assertEq(ghoOffset.totalCovered(), 150_000e18, "DAO totalCovered");
        assertTrue(ghoOffset.isBelowMinimum(), "offset below its size");
        vm.expectRevert(abi.encodeWithSelector(ICoverageSpokeErrors.NothingToCover.selector, aave.cdpSpoke));
        _coverWith(ghoOffset, aave.cdpSpoke, type(uint256).max);
    }

    // TEST-298 verifies: REQ-FLR-048, REQ-FLR-030, SPEC-FLR-006, Q-410
    /// @notice A deficit within the Avana Umbrella is covered by it alone: afterwards the offset has nothing to cover and
    /// keeps its whole balance; with a partial `maxAmount` the offset stays refused until the Avana layer is empty.
    function test_TEST_298_offsetIdleWhileAvanaLayerSuffices() public {
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 60_000e18);
        assertEq(_coverWith(ghoCoverage, aave.cdpSpoke, 20_000e18), 20_000e18, "partial first call");
        vm.prank(coverageCaller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDeficitOffsetSpoke.FirstLossLayerNotExhausted.selector, address(ghoCoverage), 80_000e18
            )
        );
        ghoOffset.coverDeficit(aave.cdpSpoke, type(uint256).max);
        assertEq(_coverWith(ghoCoverage, aave.cdpSpoke, type(uint256).max), 40_000e18, "rest from the Avana layer");
        vm.expectRevert(abi.encodeWithSelector(ICoverageSpokeErrors.NothingToCover.selector, aave.cdpSpoke));
        _coverWith(ghoOffset, aave.cdpSpoke, type(uint256).max);
        assertEq(ghoOffset.fundedBalance(), DAO_OFFSET_GHO, "DAO offset intact");
        assertEq(ghoCoverage.fundedBalance(), 40_000e18, "Avana layer left");
    }

    // TEST-298 verifies: REQ-FLR-048, REQ-FLR-050, INV-100, ATTACK-199, Q-410
    /// @notice One wei funded into an exhausted Avana Umbrella (at share price 1 it mints one share) blocks the offset
    /// again until the coverage caller spends it, so the caller sends both calls in one batch; the order still holds.
    function test_TEST_298_dustFundingIsSpentFirst() public {
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 120_000e18);
        _coverWith(ghoCoverage, aave.cdpSpoke, type(uint256).max);
        _fund(ghoCoverage, gho, address(0xD057), 1);
        vm.prank(coverageCaller);
        vm.expectRevert(
            abi.encodeWithSelector(IDeficitOffsetSpoke.FirstLossLayerNotExhausted.selector, address(ghoCoverage), 1)
        );
        ghoOffset.coverDeficit(aave.cdpSpoke, type(uint256).max);
        assertEq(_coverWith(ghoCoverage, aave.cdpSpoke, type(uint256).max), 1, "dust spent first");
        assertEq(_coverWith(ghoOffset, aave.cdpSpoke, type(uint256).max), 20_000e18 - 1, "then the offset");
        assertEq(hub.getSpokeDeficitRay(ghoAssetId, aave.cdpSpoke), 0, "cleared");
    }

    // TEST-298 verifies: REQ-FLR-036, REQ-FLR-048, REQ-FLR-050, INV-100, SPEC-FLR-006, ATTACK-199, Q-410
    /// @notice A deactivated Avana Umbrella cannot pay (`SpokeNotActive`), so the offset pays although the Umbrella still
    /// holds 100,000 GHO: the accepted trade-off of `Q-410`, DAO money spent before Avana's while the DAO keeps the
    /// Umbrella deactivated. The Umbrella's balance and shares do not move.
    function test_TEST_298_inactiveFirstLayerLetsOffsetPay() public {
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 130_000e18);
        uint256 umbrellaShares = ghoCoverage.fundedShares();
        _setActive(ghoAssetId, address(ghoCoverage), false);
        vm.prank(coverageCaller);
        vm.expectRevert(bytes4(keccak256("SpokeNotActive()")));
        ghoCoverage.coverDeficit(aave.cdpSpoke, type(uint256).max);
        assertEq(ghoCoverage.fundedBalance(), 100_000e18, "Umbrella still holds funds");

        assertEq(_coverWith(ghoOffset, aave.cdpSpoke, type(uint256).max), 130_000e18, "offset pays the whole deficit");
        assertEq(hub.getSpokeDeficitRay(ghoAssetId, aave.cdpSpoke), 0, "cleared");
        assertEq(ghoCoverage.fundedShares(), umbrellaShares, "Umbrella shares untouched");
        assertEq(ghoOffset.fundedBalance(), DAO_OFFSET_GHO - 130_000e18, "DAO offset spent");
    }

    // TEST-298 verifies: REQ-FLR-022, REQ-FLR-036, REQ-FLR-048, REQ-FLR-050, INV-100, Q-410
    /// @notice Reactivated, the Avana Umbrella is first again: the offset is refused while it holds funds. A halted
    /// Umbrella is still active (the Hub's `eliminateDeficit` checks only `active`), so it pays first, and a halted offset
    /// pays after it.
    function test_TEST_298_activeOrHaltedFirstLayerPaysFirst() public {
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 130_000e18);
        _setActive(ghoAssetId, address(ghoCoverage), false);
        _setActive(ghoAssetId, address(ghoCoverage), true);
        vm.prank(coverageCaller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDeficitOffsetSpoke.FirstLossLayerNotExhausted.selector, address(ghoCoverage), 100_000e18
            )
        );
        ghoOffset.coverDeficit(aave.cdpSpoke, type(uint256).max);

        _setHalted(ghoAssetId, address(ghoCoverage), true);
        vm.prank(coverageCaller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDeficitOffsetSpoke.FirstLossLayerNotExhausted.selector, address(ghoCoverage), 100_000e18
            )
        );
        ghoOffset.coverDeficit(aave.cdpSpoke, type(uint256).max);
        assertEq(_coverWith(ghoCoverage, aave.cdpSpoke, type(uint256).max), 100_000e18, "halted layer covers");
        _setHalted(ghoAssetId, address(ghoOffset), true);
        assertEq(_coverWith(ghoOffset, aave.cdpSpoke, type(uint256).max), 30_000e18, "halted offset covers");
    }

    // ─── Roles and allowlist ───

    // TEST-298 verifies: REQ-FLR-046, REQ-FLR-032, REQ-FLR-029, REQ-FLR-016, Q-410
    /// @notice The offset answers to the Aave DAO's AccessManager like the Avana Umbrella: `coverDeficit` needs
    /// `COVERAGE_ROLE`, the admin functions `RESERVE_ADMIN_ROLE`, and a Spoke off its own allowlist is refused even when
    /// the Avana layer is exhausted.
    function test_TEST_298_rolesAndOwnAllowlist() public {
        address stranger = address(0x5157);
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        ghoOffset.coverDeficit(aave.cdpSpoke, 1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        ghoOffset.setFirstLossReserveMinimum(0);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        ghoOffset.requestWithdrawal(1, stranger);
        vm.stopPrank();

        vm.prank(aaveGovernanceExecutor);
        ghoCoverage.setAllowedBorrowSpoke(otherSpoke, true);
        _reportDeficit(ghoAssetId, otherSpoke, 110_000e18);
        _coverWith(ghoCoverage, otherSpoke, type(uint256).max);
        assertEq(ghoCoverage.fundedBalance(), 0, "Avana layer exhausted on the other Spoke");
        vm.expectRevert(abi.encodeWithSelector(ICoverageSpokeErrors.SpokeNotAllowlisted.selector, otherSpoke));
        _coverWith(ghoOffset, otherSpoke, type(uint256).max);
        vm.prank(aaveGovernanceExecutor);
        ghoOffset.setAllowedBorrowSpoke(otherSpoke, true);
        assertEq(_coverWith(ghoOffset, otherSpoke, type(uint256).max), 10_000e18, "covered once allowlisted");
    }

    // ─── Per asset ───

    // TEST-298 verifies: REQ-FLR-040, REQ-FLR-042, REQ-FLR-048, Q-236, Q-410
    /// @notice Each asset has its own pair of layers: the GHO offset waits on the GHO Avana Umbrella only and never
    /// reduces a USDC deficit; the USDC offset covers USDC after the USDC Avana Umbrella.
    function test_TEST_298_layersPerAsset() public {
        _reportDeficit(usdcAssetId, aave.cdpSpoke, 80_000e6);
        vm.expectRevert(abi.encodeWithSelector(ICoverageSpokeErrors.NothingToCover.selector, aave.cdpSpoke));
        _coverWith(ghoOffset, aave.cdpSpoke, type(uint256).max);
        assertEq(_coverWith(usdcCoverage, aave.cdpSpoke, type(uint256).max), 50_000e6, "USDC Avana layer");
        assertEq(_coverWith(usdcOffset, aave.cdpSpoke, type(uint256).max), 30_000e6, "USDC offset");
        assertEq(ghoOffset.fundedBalance(), DAO_OFFSET_GHO, "GHO offset untouched");
        assertEq(ghoCoverage.fundedBalance(), FIRST_LOSS_RESERVE_MINIMUM_GHO, "GHO layer untouched");
        assertEq(usdcOffset.fundedBalance(), DAO_OFFSET_USDC - 30_000e6, "USDC offset left");
    }

    // ─── Withdrawals ───

    // TEST-298 verifies: REQ-FLR-049, REQ-FLR-025, REQ-FLR-026, REQ-FLR-045, SPEC-FLR-003, Q-410
    /// @notice The DAO withdraws its offset through the offset's own 14-day queue, which waits behind the deficit guard
    /// like the Avana Umbrella's; the Avana Umbrella's balance and queue do not move.
    function test_TEST_298_offsetWithdrawalIsSeparate() public {
        vm.prank(aaveGovernanceExecutor);
        uint256 id = ghoOffset.requestWithdrawal(40_000e18, daoTreasury);
        assertEq(ghoCoverage.nextWithdrawalId(), 1, "Avana queue untouched");
        vm.warp(block.timestamp + 1_209_600);
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 1000e18);
        vm.prank(aaveGovernanceExecutor);
        vm.expectRevert(abi.encodeWithSelector(ICoverageSpokeErrors.DeficitOutstanding.selector, aave.cdpSpoke));
        ghoOffset.executeWithdrawal(id);
        _coverWith(ghoCoverage, aave.cdpSpoke, type(uint256).max);

        uint256 treasuryBefore = gho.balanceOf(daoTreasury);
        vm.prank(aaveGovernanceExecutor);
        assertEq(ghoOffset.executeWithdrawal(id), 40_000e18, "withdrawn");
        assertEq(gho.balanceOf(daoTreasury) - treasuryBefore, 40_000e18, "paid to the treasury");
        assertEq(ghoOffset.fundedBalance(), DAO_OFFSET_GHO - 40_000e18, "offset left");
        assertEq(ghoCoverage.fundedBalance(), FIRST_LOSS_RESERVE_MINIMUM_GHO - 1000e18, "Avana layer only covered");
        assertEq(ghoOffset.totalWithdrawn(), 40_000e18, "offset totalWithdrawn");
        assertEq(ghoCoverage.totalWithdrawn(), 0, "Avana totalWithdrawn");
    }

    // Hub event, redeclared for `expectEmit`.
    event EliminateDeficit(
        uint256 indexed assetId,
        address indexed callerSpoke,
        address indexed coveredSpoke,
        uint256 shares,
        uint256 deficitAmountRay
    );
}
