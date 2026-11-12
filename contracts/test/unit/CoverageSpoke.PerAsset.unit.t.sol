// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CoverageSpoke} from "../../src/coverage/coverage-spoke/CoverageSpoke.sol";
import {ICoverageSpoke} from "../../src/coverage/coverage-spoke/ICoverageSpoke.sol";
import {ICoverageSpokeErrors} from "../../src/coverage/coverage-spoke/ICoverageSpokeErrors.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {CoverageSpokeFixture, ICoverageHubSpokeCalls} from "../utils/fixtures/CoverageSpokeFixture.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title CoverageSpokePerAssetUnitTest
/// @notice Per-asset coverage on the real local Aave V4 Hub (TEST-199, coverage part): a USDC deficit on the CDP
/// Spoke is reduced only by the USDC Coverage Spoke, by `min(maxAmount, ceil(deficitRay / RAY), fundedBalance())`;
/// the GHO Coverage Spoke changes it by 0 and spends no GHO; a Spoke off the allowlist reverts; coverage continues
/// while either Spoke is halted.
/// @dev Deficits are recorded by the real Hub (`draw` then `reportDeficit` from the pranked CDP Spoke). The
/// liquidation that leaves no collateral, `settlePending` funding and the listing check of TEST-199 come with
/// LPVaultSwap and the MarketRegistry.
contract CoverageSpokePerAssetUnitTest is CoverageSpokeFixture {
    bytes4 internal constant HUB_SPOKE_NOT_ACTIVE = bytes4(keccak256("SpokeNotActive()"));
    bytes4 internal constant HUB_SPOKE_HALTED = bytes4(keccak256("SpokeHalted()"));

    function setUp() public {
        _deployCoverage();
    }

    function _cover(
        CoverageSpoke cs,
        address spoke,
        uint256 maxAmount
    ) internal returns (uint256 shares, uint256 covered) {
        vm.prank(coverageCaller);
        (shares, covered) = cs.coverDeficit(spoke, maxAmount);
    }

    // TEST-199 verifies: REQ-FLR-018, REQ-FLR-019, REQ-FLR-040, REQ-FLR-042, SPEC-FLR-001, INV-042, INV-071, Q-101, Q-142, Q-236
    // Sources: 5.1 TEST-199 example, 2.14 SPEC-FLR-001, FLOW-009
    /// @notice USDC deficit 1,200e6; the USDC Coverage Spoke holds 50,000e6 and covers all of it; the GHO Coverage
    /// Spoke's balance and the GHO asset are untouched.
    function test_TEST_199_coversOwnAssetOnly() public {
        uint256 deficitRay = _reportDeficit(usdcAssetId, aave.cdpSpoke, 1200e6);
        assertEq(deficitRay, 1200e6 * RAY, "recorded deficit");
        uint256 usdcBefore = usdcCoverage.fundedBalance();
        uint256 ghoBefore = ghoCoverage.fundedBalance();
        uint256 ghoShares = ghoCoverage.fundedShares();
        uint256 expectedShares = _sharesUp(usdcAssetId, 1200e6);
        uint256 usdcSharesBefore = usdcCoverage.fundedShares();

        vm.expectEmit(address(usdcCoverage));
        emit ICoverageSpoke.DeficitCovered(
            aave.cdpSpoke, coverageCaller, 1200e6, expectedShares, deficitRay, 0, usdcBefore - 1200e6
        );
        (uint256 shares, uint256 covered) = _cover(usdcCoverage, aave.cdpSpoke, type(uint256).max);

        assertEq(covered, 1200e6, "covered");
        assertEq(shares, expectedShares, "shares burned per SPEC-FLR-001");
        assertEq(usdcCoverage.fundedShares(), usdcSharesBefore - shares, "shares held");
        assertEq(hub.getSpokeDeficitRay(usdcAssetId, aave.cdpSpoke), 0, "deficit cleared");
        assertEq(usdcCoverage.fundedBalance(), usdcBefore - 1200e6, "usdc balance");
        assertEq(usdcCoverage.totalCovered(), 1200e6, "totalCovered");
        assertEq(ghoCoverage.fundedBalance(), ghoBefore, "gho balance");
        assertEq(ghoCoverage.fundedShares(), ghoShares, "gho shares");
        assertEq(hub.getSpokeDeficitRay(ghoAssetId, aave.cdpSpoke), 0, "gho deficit");
    }

    // TEST-199 verifies: REQ-FLR-030, REQ-FLR-040, INV-071, ATTACK-090, ATTACK-130, Q-236
    /// @notice The GHO Coverage Spoke cannot reach a USDC deficit: the CDP Spoke's GHO deficit is 0, so the call
    /// reverts `NothingToCover`, the USDC deficit stays and no GHO share moves.
    function test_TEST_199_crossAssetReverts() public {
        uint256 deficitRay = _reportDeficit(usdcAssetId, aave.cdpSpoke, 1200e6);
        uint256 ghoShares = ghoCoverage.fundedShares();
        vm.expectRevert(abi.encodeWithSelector(ICoverageSpokeErrors.NothingToCover.selector, aave.cdpSpoke));
        _cover(ghoCoverage, aave.cdpSpoke, type(uint256).max);
        assertEq(hub.getSpokeDeficitRay(usdcAssetId, aave.cdpSpoke), deficitRay, "usdc deficit unchanged");
        assertEq(ghoCoverage.fundedShares(), ghoShares, "gho shares unchanged");
        assertEq(ghoCoverage.totalCovered(), 0, "gho totalCovered");
    }

    // TEST-199 verifies: REQ-FLR-016, REQ-FLR-017, REQ-FLR-029, INV-042, ATTACK-090, Q-142, Q-190
    /// @notice A Spoke with a recorded deficit that is not on the allowlist reverts `SpokeNotAllowlisted`, before and
    /// after a removal; the Hub alone would accept it (MATH-ST-50).
    function test_TEST_199_spokeNotAllowlistedReverts() public {
        _reportDeficit(ghoAssetId, otherSpoke, 500e18);
        vm.expectRevert(abi.encodeWithSelector(ICoverageSpokeErrors.SpokeNotAllowlisted.selector, otherSpoke));
        _cover(ghoCoverage, otherSpoke, type(uint256).max);

        _reportDeficit(ghoAssetId, aave.cdpSpoke, 100e18);
        vm.prank(aaveGovernanceExecutor);
        ghoCoverage.setAllowedBorrowSpoke(aave.cdpSpoke, false);
        vm.expectRevert(abi.encodeWithSelector(ICoverageSpokeErrors.SpokeNotAllowlisted.selector, aave.cdpSpoke));
        _cover(ghoCoverage, aave.cdpSpoke, type(uint256).max);
        assertEq(hub.getSpokeDeficitRay(ghoAssetId, otherSpoke), 500e18 * RAY, "other deficit unchanged");
    }

    // TEST-199 verifies: REQ-FLR-018, REQ-FLR-019, SPEC-FLR-001, INV-042, Q-101
    /// @notice `maxAmount` binds: 300 of a 475.25 GHO deficit is eliminated and 175.25 GHO stays recorded.
    function test_TEST_199_maxAmountBinds() public {
        uint256 deficitRay = _reportDeficit(ghoAssetId, aave.cdpSpoke, 475.25e18);
        (, uint256 covered) = _cover(ghoCoverage, aave.cdpSpoke, 300e18);
        assertEq(covered, 300e18, "covered");
        assertEq(hub.getSpokeDeficitRay(ghoAssetId, aave.cdpSpoke), deficitRay - 300e18 * RAY, "remainder");
        assertEq(ghoCoverage.totalCovered(), 300e18, "totalCovered");
    }

    // TEST-199 verifies: REQ-FLR-014, REQ-FLR-019, REQ-FLR-027, REQ-FLR-031, SPEC-FLR-001, INV-042, Q-102
    /// @notice The funded balance binds: a deficit above the reserve is covered up to `fundedBalance()`, the rest stays
    /// recorded on the asset, and `ReserveBelowMinimum` is emitted.
    function test_TEST_199_fundedBalanceBindsAndAlerts() public {
        uint256 funded = usdcCoverage.fundedBalance();
        uint256 deficitRay = _reportDeficit(usdcAssetId, aave.cdpSpoke, funded + 7000e6);
        vm.expectEmit(address(usdcCoverage));
        emit ICoverageSpoke.ReserveBelowMinimum(0, FIRST_LOSS_RESERVE_MINIMUM_USDC);
        (, uint256 covered) = _cover(usdcCoverage, aave.cdpSpoke, type(uint256).max);
        assertEq(covered, funded, "covered the funded balance");
        assertEq(usdcCoverage.fundedBalance(), 0, "reserve spent");
        assertEq(usdcCoverage.fundedShares(), 0, "every share burned");
        assertEq(hub.getSpokeDeficitRay(usdcAssetId, aave.cdpSpoke), deficitRay - funded * RAY, "remainder stays");
        assertTrue(usdcCoverage.isBelowMinimum(), "below minimum");
        vm.expectRevert(abi.encodeWithSelector(ICoverageSpokeErrors.NothingToCover.selector, aave.cdpSpoke));
        _cover(usdcCoverage, aave.cdpSpoke, type(uint256).max);
    }

    // TEST-199 verifies: REQ-FLR-011, REQ-FLR-014, REQ-FLR-031, Q-102, Q-399
    // Sources: 2.14 REQ-FLR-014 example (scaled to the 100,000 GHO fixture minimum)
    /// @notice A 5,200 GHO coverage leaves 94,800 GHO against the 100,000 GHO minimum: `ReserveBelowMinimum` is
    /// emitted and `isBelowMinimum()` turns true; Avana Labs funds 5,200 GHO and it clears with no reset call. A
    /// coverage that stays above the minimum emits no alert.
    function test_TEST_199_alertOnlyBelowMinimum() public {
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 5200e18);
        vm.expectEmit(address(ghoCoverage));
        emit ICoverageSpoke.ReserveBelowMinimum(94_800e18, FIRST_LOSS_RESERVE_MINIMUM_GHO);
        _cover(ghoCoverage, aave.cdpSpoke, 5200e18);
        assertTrue(ghoCoverage.isBelowMinimum(), "below after coverage");
        _fund(ghoCoverage, gho, avanaLabs, 5200e18);
        assertFalse(ghoCoverage.isBelowMinimum(), "cleared by funding");

        _fund(ghoCoverage, gho, avanaLabs, 10_000e18);
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 1000e18);
        vm.recordLogs();
        _cover(ghoCoverage, aave.cdpSpoke, 1000e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics.length == 0 || logs[i].topics[0] != ICoverageSpoke.ReserveBelowMinimum.selector,
                "no alert above the minimum"
            );
        }
        assertFalse(ghoCoverage.isBelowMinimum(), "still above");
    }

    // TEST-199 verifies: REQ-FLR-030, SPEC-FLR-001
    /// @notice A zero `maxAmount`, a Spoke with no deficit and an unfunded instance all revert `NothingToCover`.
    function test_TEST_199_nothingToCover() public {
        vm.expectRevert(abi.encodeWithSelector(ICoverageSpokeErrors.NothingToCover.selector, aave.cdpSpoke));
        _cover(ghoCoverage, aave.cdpSpoke, 1e18);
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 10e18);
        vm.expectRevert(abi.encodeWithSelector(ICoverageSpokeErrors.NothingToCover.selector, aave.cdpSpoke));
        _cover(ghoCoverage, aave.cdpSpoke, 0);

        CoverageSpoke empty = _deployCoverageSpoke(address(gho), ghoAssetId, ADD_CAP_GHO, "EmptyCoverage");
        vm.prank(aaveGovernanceExecutor);
        empty.setAllowedBorrowSpoke(aave.cdpSpoke, true);
        vm.expectRevert(abi.encodeWithSelector(ICoverageSpokeErrors.NothingToCover.selector, aave.cdpSpoke));
        _cover(empty, aave.cdpSpoke, 1e18);
    }

    // TEST-199 verifies: REQ-FLR-020, REQ-FLR-030, REQ-FLR-016, Q-071, Q-117, Q-127, Q-397
    // Sources: 2.14 REQ-FLR-020
    /// @notice The reserve covers only a deficit Aave has recorded on the Hub. With a funded reserve and no recorded
    /// deficit (a liquidation that reverted on a shortfall, a keeper's swap loss and a flash repayment record none),
    /// `coverDeficit` reverts `NothingToCover` for any `maxAmount`; LPVaultSwap, a keeper and a flash lender cannot
    /// call any function that spends the reserve; a recorded deficit is eliminated on the Hub for exactly its amount
    /// and no token leaves the Hub, so the reserve pays no party.
    /// @dev Kills: an inverted `deficitRayBefore == 0` check in `coverDeficit`, and dropping
    /// `ceilDiv(deficitRayBefore, RAY)` from the coverage minimum (the coverage would then exceed the deficit).
    function test_TEST_199_coversOnlyRecordedDeficits() public {
        uint256 shares = ghoCoverage.fundedShares();
        uint256[3] memory asks = [uint256(1), 1000e18, type(uint256).max];
        for (uint256 i = 0; i < asks.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ICoverageSpokeErrors.NothingToCover.selector, aave.cdpSpoke));
            _cover(ghoCoverage, aave.cdpSpoke, asks[i]);
        }
        assertEq(ghoCoverage.fundedShares(), shares, "nothing spent without a recorded deficit");

        address[3] memory others = [makeAddr("lpVaultSwap"), makeAddr("keeper"), makeAddr("flashLender")];
        for (uint256 i = 0; i < others.length; ++i) {
            vm.startPrank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, others[i]));
            ghoCoverage.coverDeficit(aave.cdpSpoke, 1);
            vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, others[i]));
            ghoCoverage.requestWithdrawal(1, others[i]);
            vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, others[i]));
            ghoCoverage.executeWithdrawal(1);
            vm.stopPrank();
        }

        uint256 deficitRay = _reportDeficit(ghoAssetId, aave.cdpSpoke, 400e18);
        uint256 hubTokens = gho.balanceOf(aave.hub);
        (, uint256 covered) = _cover(ghoCoverage, aave.cdpSpoke, type(uint256).max);
        assertEq(covered, deficitRay / RAY, "exactly the recorded deficit");
        assertEq(ghoCoverage.totalCovered(), deficitRay / RAY, "the reserve counts exactly the recorded deficit");
        assertEq(hub.getSpokeDeficitRay(ghoAssetId, aave.cdpSpoke), 0, "deficit eliminated");
        assertEq(gho.balanceOf(aave.hub), hubTokens, "no token leaves the Hub");
        assertEq(gho.balanceOf(coverageCaller), 0, "the caller receives nothing");
        assertEq(gho.balanceOf(address(ghoCoverage)), 0, "the Coverage Spoke receives nothing");
    }

    // TEST-199 verifies: REQ-FLR-016, REQ-FLR-032, Q-101
    /// @notice Only `COVERAGE_ROLE` covers: the DAO executor, Avana Labs, the governance multisig and a stranger are
    /// refused with `AccessManagedUnauthorized`.
    function test_TEST_199_onlyCoverageRole() public {
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 10e18);
        address[4] memory callers = [aaveGovernanceExecutor, avanaLabs, governanceMultisig, attacker];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, callers[i]));
            vm.prank(callers[i]);
            ghoCoverage.coverDeficit(aave.cdpSpoke, 10e18);
        }
    }

    // TEST-199 verifies: REQ-FLR-022, REQ-FLR-035, REQ-FLR-036, Q-051, Q-140, Q-290
    /// @notice Coverage continues while the Coverage Spoke and the CDP Spoke are halted (funding stops); it stops only
    /// when the DAO deactivates the Coverage Spoke.
    function test_TEST_199_haltedSpokesStillCovered() public {
        _reportDeficit(ghoAssetId, aave.cdpSpoke, 3000e18);
        _setHalted(ghoAssetId, aave.cdpSpoke, true);
        _setHalted(ghoAssetId, address(ghoCoverage), true);
        (, uint256 covered) = _cover(ghoCoverage, aave.cdpSpoke, 3000e18);
        assertEq(covered, 3000e18, "covered while halted");
        assertEq(hub.getSpokeDeficitRay(ghoAssetId, aave.cdpSpoke), 0, "cleared");

        gho.mint(avanaLabs, 1e18);
        vm.startPrank(avanaLabs);
        gho.approve(address(ghoCoverage), 1e18);
        vm.expectRevert(HUB_SPOKE_HALTED);
        ghoCoverage.fund(1e18);
        vm.stopPrank();

        _setHalted(ghoAssetId, address(ghoCoverage), false);
        _reportDeficit(ghoAssetId, otherSpoke, 1e18);
        vm.prank(aaveGovernanceExecutor);
        ghoCoverage.setAllowedBorrowSpoke(otherSpoke, true);
        _setActive(ghoAssetId, address(ghoCoverage), false);
        vm.expectRevert(HUB_SPOKE_NOT_ACTIVE);
        _cover(ghoCoverage, otherSpoke, 1e18);
    }

    // TEST-199 verifies: REQ-FLR-018, REQ-FLR-019, SPEC-FLR-001, SPEC-FLR-002, INV-042, Q-101, Q-142
    // Sources: MATH-ST-46, MATH-ST-47, MATH-ST-48, MATH-ST-49, MATH-ST-114
    /// @notice On the real Hub, with interest accrued (A > S) and a deficit that carries a sub-unit RAY remainder:
    /// covered equals `min(maxAmount, ceil(deficitRay / RAY), fundedBalance())`, the shares burned equal
    /// `ceil(covered × (S + 1e6) / (A + 1e6))`, the recorded deficit falls by exactly `dRay`, the balance falls by at
    /// least `covered`, and the Lend Spoke's assets (other suppliers) do not fall.
    function testFuzz_TEST_199_coverageIsThreeWayMin(
        uint256 drawn,
        uint256 lost,
        uint256 maxAmount,
        uint256 elapsed
    ) public {
        drawn = bound(drawn, 1e18, 500_000e18);
        lost = bound(lost, 1e6, drawn);
        elapsed = bound(elapsed, 1, 730 days);
        _draw(ghoAssetId, aave.cdpSpoke, drawn);
        vm.warp(block.timestamp + elapsed);
        vm.prank(aave.cdpSpoke);
        ICoverageHubSpokeCalls(aave.hub).reportDeficit(ghoAssetId, lost, IAaveV4Hub.PremiumDelta(0, 0, 0));
        uint256 deficitRay = hub.getSpokeDeficitRay(ghoAssetId, aave.cdpSpoke);
        uint256 funded = ghoCoverage.fundedBalance();
        maxAmount = bound(maxAmount, 1, 2 * (deficitRay / RAY + 1));
        uint256 expected = _min(_min(maxAmount, (deficitRay + RAY - 1) / RAY), funded);
        uint256 expectedShares = _sharesUp(ghoAssetId, expected);
        uint256 lendBefore = hub.getSpokeAddedAssets(ghoAssetId, aave.lendSpoke);

        (uint256 shares, uint256 covered) = _cover(ghoCoverage, aave.cdpSpoke, maxAmount);

        assertEq(covered, expected, "three-way minimum");
        assertEq(shares, expectedShares, "shares rounded up");
        uint256 dRay = expected < (deficitRay + RAY - 1) / RAY ? expected * RAY : deficitRay;
        assertEq(hub.getSpokeDeficitRay(ghoAssetId, aave.cdpSpoke), deficitRay - dRay, "deficit falls by dRay");
        assertLe(dRay, deficitRay, "never above the recorded deficit");
        assertLe(ghoCoverage.fundedBalance() + covered, funded + 1, "balance falls by covered, up to the floor");
        assertGe(hub.getSpokeAddedAssets(ghoAssetId, aave.lendSpoke), lendBefore, "other suppliers do not lose");
        assertEq(ghoCoverage.totalCovered(), covered, "totalCovered");
    }

    // TEST-199 verifies: REQ-FLR-016, REQ-FLR-018, REQ-FLR-019, REQ-FLR-029, REQ-FLR-030, REQ-FLR-031, REQ-FLR-032, SPEC-FLR-001, INV-042, Q-142, Q-190
    // Sources: fuzz twin of PROP-039 (Halmos TIMEOUT on the division by RAY)
    /// forge-config: default.fuzz.runs = 10000
    /// @notice For any caller, Spoke, deficit and `maxAmount`: `coverDeficit` succeeds exactly when the caller holds
    /// `COVERAGE_ROLE`, the Spoke is allowlisted and the deficit and `maxAmount` are non-zero (the reserve is funded),
    /// and then covers `min(maxAmount, deficit, fundedBalance())`; otherwise nothing is covered.
    function testFuzz_TEST_199_coverOnlyByRoleForAllowlistedAndLive(
        uint256 callerSeed,
        bool allowlisted,
        uint256 maxAmount,
        uint256 lost
    ) public {
        uint256 pick = callerSeed % 3;
        address caller = pick == 0
            ? coverageCaller
            : (pick == 1 ? aaveGovernanceExecutor : _boundStranger(address(uint160(callerSeed))));
        address spoke = allowlisted ? aave.cdpSpoke : otherSpoke;
        lost = bound(lost, 0, 300_000e18);
        maxAmount = bound(maxAmount, 0, 400_000e18);
        if (lost > 0) _reportDeficit(ghoAssetId, spoke, lost);
        uint256 funded = ghoCoverage.fundedBalance();
        bool live = caller == coverageCaller && allowlisted && lost > 0 && maxAmount > 0;
        vm.prank(caller);
        (bool ok, bytes memory ret) =
            address(ghoCoverage).call(abi.encodeCall(ICoverageSpoke.coverDeficit, (spoke, maxAmount)));
        assertEq(ok, live, "succeeds exactly for the role, an allowlisted Spoke and non-zero inputs");
        if (ok) {
            (, uint256 covered) = abi.decode(ret, (uint256, uint256));
            assertEq(covered, _min(_min(maxAmount, lost), funded), "three-way minimum");
        } else {
            assertEq(ghoCoverage.totalCovered(), 0, "nothing covered");
            assertEq(hub.getSpokeDeficitRay(ghoAssetId, spoke), lost * RAY, "deficit unchanged");
        }
    }

    // ─── Helpers ───

    function _min(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
