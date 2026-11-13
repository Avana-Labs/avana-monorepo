// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {HubAssetView} from "../../src/lens/lens/types/HubAssetView.sol";
import {SpokeKind} from "../../src/lens/lens/types/SpokeKind.sol";
import {CollHubSpokeConfig, ICollHubConfigurator} from "../utils/fixtures/CollateralizationFixture.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensHubAssetSlicesFuzzTest
/// @notice With a second CDP Spoke drawing on the GHO asset next to the market's, for any draws, repayments of the
/// market's account and time: the CDP slices' owed sum to the Hub's owed within their rounding, every Spoke of the asset
/// has one kind, and the available liquidity is the Hub's.
/// forge-config: default.isolate = false
contract LensHubAssetSlicesFuzzTest is LensFixture {
    address internal spokeX = makeAddr("cdpSpokeX");

    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, 200_000e6);
        vm.prank(aaveDao);
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, spokeX, ghoAssetId, CollHubSpokeConfig(0, 400_000, 1000, true, false));
        reg.addSpoke(spokeX, aave.hub);
    }

    // TEST-247 verifies: REQ-LENS-058, REQ-LENS-059
    function testFuzz_TEST_247_cdpSlicesShareTheHub(
        uint256 a,
        uint256 x,
        uint256 dt
    ) public {
        _borrow(aliceProxy, bound(a, 1e18, 200_000e18));
        vm.prank(spokeX);
        (bool ok,) = aave.hub
            .call(
                abi.encodeWithSignature("draw(uint256,uint256,address)", ghoAssetId, bound(x, 1e18, 300_000e18), spokeX)
            );
        require(ok, "draw");
        vm.warp(block.timestamp + bound(dt, 0, 1000 days));
        HubAssetView memory v = lens.getHubAsset(aave.hub, ghoAssetId);
        uint256 cdpOwed = 0;
        uint256 cdpCount = 0;
        uint256 lendCount = 0;
        for (uint256 i = 0; i < v.spokes.length; ++i) {
            if (v.spokes[i].kind == SpokeKind.Cdp) {
                cdpOwed += v.spokes[i].drawn;
                ++cdpCount;
            } else {
                assertEq(v.spokes[i].drawn, 0, "only CDP Spokes draw");
                if (v.spokes[i].kind == SpokeKind.Lend) ++lendCount;
            }
        }
        assertEq(cdpCount, 2, "two CDP Spokes");
        assertEq(lendCount, 1, "one Lend Spoke");
        assertGe(cdpOwed, v.owed, "per-Spoke owed rounds up");
        assertLe(cdpOwed, v.owed + 4, "by at most two units per CDP Spoke");
        assertApproxEqAbs(v.liquidity + v.owed, v.added + v.accruedFees, 3, "available = added + fees - owed");
        assertEq(v.utilizationBps, (v.drawn + v.premium) * 1e4 / v.added, "utilization");
    }
}
