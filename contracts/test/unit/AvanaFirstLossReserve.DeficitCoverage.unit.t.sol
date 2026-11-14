// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaFirstLossReserve} from "../../src/coverage/first-loss-reserve/AvanaFirstLossReserve.sol";
import {IAvanaFirstLossReserveErrors} from "../../src/coverage/first-loss-reserve/IAvanaFirstLossReserveErrors.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {AvanaFirstLossReserveFixture, ICoverageHubSpokeCalls} from "../utils/fixtures/AvanaFirstLossReserveFixture.sol";

/// @title AvanaFirstLossReserveDeficitCoverageUnitTest
/// @notice TEST-128 run locally on the pinned Aave V4 release (the Hub, HubConfigurator and AccessManager of the
/// local deployment, the same bytecode the fork run deploys): for the GHO reserve and a USDC reserve, `COVERAGE_ROLE`
/// calls `coverDeficit(borrowSpoke, maxAmount)` on that asset's First-Loss Reserve, which calls `Hub.eliminateDeficit` on
/// its own `(Hub, assetId)` only, for Borrow Spokes on the DAO's allowlist; the amount is at most the recorded deficit
/// in that asset and that First-Loss Reserve's funded balance; a USDC deficit is never reduced by the GHO First-Loss Reserve;
/// and the other suppliers' share price does not fall.
/// @dev The tokens are the fixture's GHO and USDC mocks; the fork run against the deployed tokens (TEST-128,
/// `DeficitCoverage.fork.t.sol`, `RPC_MAINNET`) checks the same assertions with the live token contracts.
contract AvanaFirstLossReserveDeficitCoverageUnitTest is AvanaFirstLossReserveFixture {
    function setUp() public {
        _deployCoverage();
        // Ordinary debt on both assets, so supply interest has accrued and the share price is above one.
        _draw(ghoAssetId, aave.cdpSpoke, 600_000e18);
        _draw(usdcAssetId, aave.cdpSpoke, 600_000e6);
        vm.warp(block.timestamp + 90 days);
    }

    function _instances()
        internal
        view
        returns (AvanaFirstLossReserve[2] memory cs, uint256[2] memory ids, uint256[2] memory u)
    {
        cs = [ghoCoverage, usdcCoverage];
        ids = [ghoAssetId, usdcAssetId];
        u = [uint256(1e18), 1e6];
    }

    function _cover(
        AvanaFirstLossReserve cs,
        address spoke,
        uint256 maxAmount
    ) internal returns (uint256 covered) {
        vm.prank(coverageCaller);
        (, covered) = cs.coverDeficit(spoke, maxAmount);
    }

    // TEST-128 verifies: REQ-FLR-016, REQ-FLR-029, REQ-FLR-040, REQ-FLR-004, INV-042, Q-142, Q-190
    // Sources: 5.1 TEST-128
    /// @notice For each asset, a Spoke off the allowlist is refused even with a recorded deficit; the allowlisted CDP
    /// Spoke is covered with exactly one `eliminateDeficit` on the instance's own asset ID; over the whole test each
    /// asset ID sees exactly one, so neither instance calls the other's.
    function test_TEST_128_allowlistOnly() public {
        (AvanaFirstLossReserve[2] memory cs, uint256[2] memory ids, uint256[2] memory u) = _instances();
        vm.expectCall(aave.hub, abi.encodeWithSelector(IAaveV4Hub.eliminateDeficit.selector, ids[0]), 1);
        vm.expectCall(aave.hub, abi.encodeWithSelector(IAaveV4Hub.eliminateDeficit.selector, ids[1]), 1);
        for (uint256 a = 0; a < 2; ++a) {
            uint256 otherRay = _reportDeficit(ids[a], otherSpoke, 700 * u[a]);
            vm.expectRevert(
                abi.encodeWithSelector(IAvanaFirstLossReserveErrors.SpokeNotAllowlisted.selector, otherSpoke)
            );
            _cover(cs[a], otherSpoke, type(uint256).max);
            assertEq(hub.getSpokeDeficitRay(ids[a], otherSpoke), otherRay, "off-list deficit stays");

            uint256 owed = (_reportDeficit(ids[a], aave.cdpSpoke, 300 * u[a]) + RAY - 1) / RAY;
            vm.expectCall(
                aave.hub, abi.encodeWithSelector(IAaveV4Hub.eliminateDeficit.selector, ids[a], owed, aave.cdpSpoke), 1
            );
            assertEq(_cover(cs[a], aave.cdpSpoke, type(uint256).max), owed, "covered on its own asset");
            assertEq(hub.getSpokeDeficitRay(ids[a], aave.cdpSpoke), 0, "deficit cleared");
        }
    }

    // TEST-128 verifies: REQ-FLR-018, REQ-FLR-019, REQ-FLR-031, SPEC-FLR-001, INV-042, Q-101
    // Sources: 5.1 TEST-128, MATH-ST-46…MATH-ST-50
    /// @notice For either asset, any deficit and any `maxAmount`: the amount is at most the recorded deficit
    /// (`ceil(deficitRay / RAY)`) and the instance's funded balance, the recorded deficit never falls below 0 or by
    /// more than it held, and the rest stays recorded.
    function testFuzz_TEST_128_amountBounded(
        bool usdcSide,
        uint256 lost,
        uint256 maxAmount,
        uint256 extraFund
    ) public {
        (AvanaFirstLossReserve[2] memory cs, uint256[2] memory ids, uint256[2] memory u) = _instances();
        uint256 a = usdcSide ? 1 : 0;
        lost = bound(lost, 1, 400_000 * u[a]);
        extraFund = bound(extraFund, 0, 100_000) * u[a];
        if (extraFund > 0) _fund(cs[a], a == 0 ? gho : usdc, avanaLabs, extraFund);
        vm.prank(aave.cdpSpoke);
        ICoverageHubSpokeCalls(aave.hub).reportDeficit(ids[a], lost, IAaveV4Hub.PremiumDelta(0, 0, 0));
        uint256 deficitRay = hub.getSpokeDeficitRay(ids[a], aave.cdpSpoke);
        uint256 funded = cs[a].fundedBalance();
        maxAmount = bound(maxAmount, 1, 2 * lost);
        if (deficitRay == 0) {
            // A report that rounds to no recorded deficit leaves nothing to cover.
            vm.expectRevert(abi.encodeWithSelector(IAvanaFirstLossReserveErrors.NothingToCover.selector, aave.cdpSpoke));
            _cover(cs[a], aave.cdpSpoke, maxAmount);
            return;
        }

        uint256 covered = _cover(cs[a], aave.cdpSpoke, maxAmount);

        uint256 deficitUnits = (deficitRay + RAY - 1) / RAY;
        assertLe(covered, deficitUnits, "at most the recorded deficit");
        assertLe(covered, funded, "at most the funded balance");
        assertLe(covered, maxAmount, "at most maxAmount");
        uint256 left = hub.getSpokeDeficitRay(ids[a], aave.cdpSpoke);
        assertLe(left, deficitRay, "the deficit only falls");
        assertEq(left == 0, covered == deficitUnits, "cleared exactly when the whole deficit is covered");
    }

    // TEST-128 verifies: REQ-FLR-040, REQ-FLR-042, REQ-FLR-012, INV-071, INV-042, Q-236
    // Sources: 5.1 TEST-128
    /// @notice A USDC deficit is never reduced by the GHO First-Loss Reserve (no GHO deficit, so `NothingToCover`, and no
    /// GHO share moves); covering it with the USDC First-Loss Reserve and a GHO deficit with the GHO First-Loss Reserve leaves
    /// the Lend Spoke's assets per share on each asset at least where they were.
    function test_TEST_128_sharePriceNotLower() public {
        uint256 usdcRay = _reportDeficit(usdcAssetId, aave.cdpSpoke, 25_000e6);
        uint256 ghoShares = ghoCoverage.fundedShares();
        vm.expectRevert(abi.encodeWithSelector(IAvanaFirstLossReserveErrors.NothingToCover.selector, aave.cdpSpoke));
        _cover(ghoCoverage, aave.cdpSpoke, type(uint256).max);
        assertEq(hub.getSpokeDeficitRay(usdcAssetId, aave.cdpSpoke), usdcRay, "the GHO reserve cannot reach USDC");
        assertEq(ghoCoverage.fundedShares(), ghoShares, "no GHO share moved");

        _reportDeficit(ghoAssetId, aave.cdpSpoke, 40_000e18);
        (AvanaFirstLossReserve[2] memory cs, uint256[2] memory ids,) = _instances();
        for (uint256 a = 0; a < 2; ++a) {
            uint256 lendAssets = hub.getSpokeAddedAssets(ids[a], aave.lendSpoke);
            uint256 lendShares = hub.getSpokeAddedShares(ids[a], aave.lendSpoke);
            uint256 assets = hub.getAddedAssets(ids[a]) + 1e6;
            uint256 shares = hub.getAddedShares(ids[a]) + 1e6;
            _cover(cs[a], aave.cdpSpoke, type(uint256).max);
            assertEq(hub.getSpokeDeficitRay(ids[a], aave.cdpSpoke), 0, "deficit cleared");
            assertEq(hub.getSpokeAddedShares(ids[a], aave.lendSpoke), lendShares, "the Lend Spoke keeps its shares");
            assertGe(hub.getSpokeAddedAssets(ids[a], aave.lendSpoke), lendAssets, "other suppliers do not lose");
            // (A' + 1e6) / (S' + 1e6) >= (A + 1e6) / (S + 1e6), cross-multiplied.
            assertGe(
                (hub.getAddedAssets(ids[a]) + 1e6) * shares,
                assets * (hub.getAddedShares(ids[a]) + 1e6),
                "the share price does not fall"
            );
        }
    }
}
