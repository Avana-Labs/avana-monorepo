// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILensHubReads} from "../../src/lens/lens/ILensHubReads.sol";
import {HubAssetExposureView, SpokeDraw} from "../../src/lens/lens/types/HubAssetExposureView.sol";
import {HubAssetView} from "../../src/lens/lens/types/HubAssetView.sol";
import {SpokeKind} from "../../src/lens/lens/types/SpokeKind.sol";
import {CollHubSpokeConfig, ICollHubConfigurator} from "../utils/fixtures/CollateralizationFixture.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensHubAssetSlicesUnitTest
/// @notice The allocation of one lend asset across two CDP Spokes on the real Aave V4 Hub (the second, a later AMM
/// protocol's Spoke, draws directly on the Hub): each slice's owed, draw cap and headroom, the idle liquidity, and the
/// sums the Lend page shows; the USDC asset at 6 decimals; a Spoke whose home Hub differs (a cross-Hub line).
/// forge-config: default.isolate = false
contract LensHubAssetSlicesUnitTest is LensFixture {
    address internal spokeX = makeAddr("cdpSpokeX");
    address internal otherHub = makeAddr("otherHub");

    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, 50_000e6);
        vm.prank(aaveDao);
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, spokeX, ghoAssetId, CollHubSpokeConfig(0, 300_000, 1000, true, false));
        reg.addSpoke(spokeX, otherHub);
    }

    function _slice(
        HubAssetView memory v,
        address spoke
    ) internal pure returns (SpokeDraw memory) {
        for (uint256 i = 0; i < v.spokes.length; ++i) {
            if (v.spokes[i].spoke == spoke) return v.spokes[i];
        }
        revert("no slice");
    }

    function _drawX(
        uint256 amount
    ) internal {
        vm.prank(spokeX);
        (bool ok,) = aave.hub.call(abi.encodeWithSignature("draw(uint256,uint256,address)", ghoAssetId, amount, spokeX));
        require(ok, "draw");
    }

    // TEST-247 verifies: REQ-LENS-058, REQ-LENS-059
    function test_TEST_247_twoCdpSpokesShareTheAsset() public {
        _borrow(aliceProxy, 10_000e18);
        _drawX(20_000e18);
        HubAssetView memory v = lens.getHubAsset(aave.hub, ghoAssetId);
        SpokeDraw memory u = _slice(v, aave.cdpSpoke);
        SpokeDraw memory x = _slice(v, spokeX);
        assertEq(uint8(u.kind), uint8(SpokeKind.Cdp), "U is a CDP Spoke");
        assertEq(uint8(x.kind), uint8(SpokeKind.Cdp), "X too");
        assertEq(x.homeHub, otherHub, "X's home Hub differs: a cross-Hub line");
        assertEq(u.drawn, 10_000e18, "U owes 10,000");
        assertEq(x.drawn, 20_000e18, "X owes 20,000");
        assertEq(x.drawCap, 300_000, "X's draw cap");
        assertEq(u.drawn + x.drawn, v.owed, "the Lend page's borrowed = the sum of the CDP slices");
        assertEq(v.liquidity, v.added - v.owed, "idle = added - owed before any fee or deficit");
        assertEq(v.utilizationBps, 300, "30,000 of 1,000,000");
        assertEq(_slice(v, aave.lendSpoke).added, v.added, "every supplied unit came through the Lend Spoke");
    }

    // TEST-247 verifies: REQ-LENS-059
    function test_TEST_247_slicesAfterInterestStillReconcile() public {
        _borrow(aliceProxy, 10_000e18);
        _drawX(20_000e18);
        vm.warp(block.timestamp + 500 days);
        HubAssetView memory v = lens.getHubAsset(aave.hub, ghoAssetId);
        SpokeDraw memory u = _slice(v, aave.cdpSpoke);
        SpokeDraw memory x = _slice(v, spokeX);
        assertGt(x.drawn, 20_000e18, "interest accrued");
        assertEq(u.drawnShares + x.drawnShares, v.drawnShares, "drawn shares exactly");
        assertGe(u.drawn + x.drawn, v.owed, "per-Spoke owed rounds up");
        assertLe(u.drawn + x.drawn, v.owed + 4, "by at most two units per Spoke");
        assertEq(v.owed, ILensHubReads(aave.hub).getAssetTotalOwed(ghoAssetId), "the Hub's owed");
    }

    // TEST-247 verifies: REQ-LENS-043, REQ-LENS-059
    function test_TEST_247_exposureListsBothCdpSlices() public {
        _borrow(aliceProxy, 5000e18);
        _drawX(7000e18);
        HubAssetExposureView memory e = lens.getHubAssetExposure(aave.hub, address(debt));
        uint256 cdp = 0;
        uint256 owed = 0;
        for (uint256 i = 0; i < e.spokes.length; ++i) {
            if (e.spokes[i].kind == SpokeKind.Cdp) {
                ++cdp;
                owed += e.spokes[i].drawn;
            }
        }
        assertEq(cdp, 2, "two CDP slices");
        assertEq(owed, 12_000e18, "their owed");
    }

    // TEST-247 verifies: REQ-LENS-058
    function test_TEST_247_usdcAssetAtSixDecimals() public {
        _borrowUsdc(aliceProxy, 25_000e6);
        HubAssetView memory v = lens.getHubAsset(aave.hub, usdcAssetId);
        assertEq(v.underlying, address(usdc), "USDC");
        assertEq(v.decimals, 6, "6 decimals");
        assertEq(v.added, 1_000_000e6, "the Lend Spoke's 1,000,000 USDC");
        assertEq(v.owed, 25_000e6, "owed");
        assertEq(v.liquidity, 975_000e6, "available");
        assertEq(v.utilizationBps, 250, "2.5 %");
        assertEq(v.lendSpoke, aave.lendSpoke, "Lend Spoke");
        assertEq(v.priceUsd8, 0.9999e8, "the Lend Spoke's oracle price of USDC");
        assertEq(uint8(_slice(v, aave.cdpSpoke).kind), uint8(SpokeKind.Cdp), "CDP");
        assertEq(_slice(v, aave.cdpSpoke).drawCap, 500_000, "the CDP Spoke's USDC draw cap");
    }

    // TEST-247 verifies: REQ-LENS-058
    function test_TEST_247_lendAssetWithoutBorrowersHasAView() public view {
        // An asset only the Lend Spoke lists: the view is keyed by (hub, assetId), not by a debt reserve.
        HubAssetView memory v = lens.getHubAsset(aave.hub, usdcAssetId);
        assertEq(v.owed, 0, "no borrower yet");
        assertEq(v.utilizationBps, 0, "0 %");
        assertEq(v.supplyRateRay, 0, "nothing earned");
        assertEq(v.liquidity, v.added, "all available");
    }
}
