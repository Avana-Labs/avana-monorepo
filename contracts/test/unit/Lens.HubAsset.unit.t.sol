// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {ILensErrors} from "../../src/lens/lens/ILensErrors.sol";
import {ILensHubReads} from "../../src/lens/lens/ILensHubReads.sol";
import {HubAssetExposureView, SpokeDraw} from "../../src/lens/lens/types/HubAssetExposureView.sol";
import {HubAssetView} from "../../src/lens/lens/types/HubAssetView.sol";
import {SpokeKind} from "../../src/lens/lens/types/SpokeKind.sol";
import {CollHubSpokeConfig, ICollHubConfigurator} from "../utils/fixtures/CollateralizationFixture.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensHubAssetUnitTest
/// @notice `getHubAsset` on the real Aave V4 Hub: the asset's totals, its available liquidity (the Hub's liquidity, not
/// supplied minus drawn), rates, rate curve and Lend-Spoke price, and one slice per Spoke with its kind; the slices add up
/// to the Hub's figures in the same block.
/// forge-config: default.isolate = false
contract LensHubAssetUnitTest is LensFixture {
    /// @dev Aave V4 `SharesMath.VIRTUAL_SHARES` and `VIRTUAL_ASSETS`.
    uint256 internal constant VIRTUAL = 1e6;

    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, 100_000e6);
    }

    function _addSpoke(
        address spoke,
        uint256 assetId
    ) internal {
        vm.prank(aaveDao);
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, spoke, assetId, CollHubSpokeConfig(1000, 0, 1000, true, false));
    }

    function _slice(
        HubAssetView memory v,
        address spoke
    ) internal pure returns (SpokeDraw memory d) {
        for (uint256 i = 0; i < v.spokes.length; ++i) {
            if (v.spokes[i].spoke == spoke) return v.spokes[i];
        }
        revert("no slice");
    }

    // TEST-247 verifies: REQ-LENS-058, REQ-LENS-059, REQ-LENS-005
    function test_TEST_247_hubAssetTotalsRatesAndPrice() public {
        _borrow(aliceProxy, 8000e18);
        HubAssetView memory v = lens.getHubAsset(aave.hub, ghoAssetId);
        assertEq(v.blockNumber, block.number, "block");
        assertEq(v.timestamp, block.timestamp, "time");
        assertEq(v.hub, aave.hub, "hub");
        assertEq(v.assetId, ghoAssetId, "asset");
        assertEq(v.underlying, address(debt), "GHO");
        assertEq(v.decimals, 18, "decimals");
        assertEq(v.added, 1_000_000e18, "the DAO's supply");
        assertEq(v.addedShares, 1_000_000e18, "shares");
        assertEq(v.owed, 8000e18, "owed");
        assertEq(v.drawn + v.premium, v.owed, "owed = drawn + premium");
        assertEq(v.liquidity, 992_000e18, "available = the Hub's liquidity");
        assertEq(v.utilizationBps, 80, "8,000 of 1,000,000");
        IAaveV4Hub.AssetConfig memory cfg = IAaveV4Hub(aave.hub).getAssetConfig(ghoAssetId);
        assertEq(v.feeReceiver, cfg.feeReceiver, "fee receiver");
        assertEq(v.irStrategy, cfg.irStrategy, "strategy");
        assertEq(v.drawnRateRay, ILensHubReads(aave.hub).getAssetDrawnRate(ghoAssetId), "drawn rate");
        assertEq(v.supplyRateRay, v.drawnRateRay * 8000e18 / 1_000_000e18, "drawn rate x usage, no fee");
        assertEq(v.optimalUsageBps, 9000, "optimal usage");
        assertEq(v.rateGrowthBeforeOptimalBps, 400, "slope 1");
        assertEq(v.rateGrowthAfterOptimalBps, 6000, "slope 2");
        assertEq(v.lendSpoke, aave.lendSpoke, "the Lend Spoke");
        assertEq(v.priceUsd8, 1e8, "the Lend Spoke's oracle price");
        assertEq(v.deficit + v.accruedFees + v.swept, 0, "fresh");
    }

    // TEST-247 verifies: REQ-LENS-058, REQ-LENS-059
    function test_TEST_247_slicesCarryKindCapsAndShares() public {
        _borrow(aliceProxy, 8000e18);
        _setDrawCap(ghoAssetId, aave.cdpSpoke, 750_000);
        _hubConfig(
            abi.encodeWithSignature(
                "updateSpokeHalted(address,uint256,address,bool)", aave.hub, ghoAssetId, aave.lendSpoke, true
            )
        );
        _addSpoke(address(ghoCov), ghoAssetId);
        HubAssetView memory v = lens.getHubAsset(aave.hub, ghoAssetId);
        assertEq(v.spokes.length, 4, "fee receiver, Lend, CDP, Coverage");
        SpokeDraw memory cdp = _slice(v, aave.cdpSpoke);
        assertEq(uint8(cdp.kind), uint8(SpokeKind.Cdp), "CDP");
        assertEq(cdp.homeHub, aave.hub, "home Hub");
        assertEq(cdp.drawCap, 750_000, "draw cap");
        assertEq(cdp.drawn, 8000e18, "owed");
        assertEq(cdp.drawnOwed + cdp.premiumOwed, cdp.drawn, "split");
        assertEq(cdp.drawnShares, ILensHubReads(aave.hub).getSpokeDrawnShares(ghoAssetId, aave.cdpSpoke), "shares");
        assertTrue(cdp.active && !cdp.halted, "active");
        SpokeDraw memory lend = _slice(v, aave.lendSpoke);
        assertEq(uint8(lend.kind), uint8(SpokeKind.Lend), "Lend");
        assertEq(lend.added, 1_000_000e18, "the lenders' supply");
        assertEq(lend.addedShares, 1_000_000e18, "shares");
        assertEq(lend.addCap, IAaveV4Hub(aave.hub).MAX_ALLOWED_SPOKE_CAP(), "no add cap");
        assertTrue(lend.halted, "halted");
        assertEq(uint8(_slice(v, v.feeReceiver).kind), uint8(SpokeKind.FeeReceiver), "fee receiver");
        SpokeDraw memory cov = _slice(v, address(ghoCov));
        assertEq(uint8(cov.kind), uint8(SpokeKind.Coverage), "Coverage");
        assertEq(cov.addCap, 1000, "its add cap");
    }

    // TEST-247 verifies: REQ-LENS-059
    function test_TEST_247_slicesReconcileToTheHub() public {
        _borrow(aliceProxy, 30_000e18);
        _open(bob, bobProxy, 2, 50_000e6);
        _spokeConfig(
            abi.encodeWithSignature("updateCollateralRisk(address,uint256,uint256)", aave.cdpSpoke, vtReserveId, 1500)
        );
        _borrow(bobProxy, 20_000e18);
        _hubConfig(abi.encodeWithSignature("updateLiquidityFee(address,uint256,uint256)", aave.hub, ghoAssetId, 1000));
        vm.warp(block.timestamp + 200 days);
        _assertReconciles(lens.getHubAsset(aave.hub, ghoAssetId));
        _borrowUsdc(aliceProxy, 40_000e6);
        vm.warp(block.timestamp + 33 days);
        _assertReconciles(lens.getHubAsset(aave.hub, usdcAssetId));
        _assertReconciles(lens.getHubAsset(aave.hub, vtAssetId));
    }

    function _assertReconciles(
        HubAssetView memory v
    ) internal pure {
        uint256 added;
        uint256 addedShares;
        uint256 owed;
        uint256 drawnShares;
        uint256 premiumShares;
        for (uint256 i = 0; i < v.spokes.length; ++i) {
            added += v.spokes[i].added;
            addedShares += v.spokes[i].addedShares;
            owed += v.spokes[i].drawn;
            drawnShares += v.spokes[i].drawnShares;
            premiumShares += v.spokes[i].premiumShares;
        }
        uint256 n = v.spokes.length;
        assertEq(addedShares, v.addedShares, "added shares add up exactly");
        assertEq(drawnShares, v.drawnShares, "drawn shares add up exactly");
        assertEq(premiumShares, v.premiumShares, "premium shares add up exactly");
        assertLe(added, v.added, "slice added assets round down");
        // Aave V4 converts with 1e6 virtual shares and assets, which hold V x (A - S) / (S + V) of the added assets.
        uint256 virtualPart = VIRTUAL * (v.added - v.addedShares) / (v.addedShares + VIRTUAL) + 1;
        assertGe(added + n + virtualPart, v.added, "within one unit per Spoke and the virtual share");
        assertGe(owed, v.owed, "slice owed rounds up");
        assertLe(owed, v.owed + 2 * n, "within two units per Spoke");
        // Hub balance: added + accrued fees = liquidity + swept + owed + deficit, each read rounding on its own.
        uint256 left = v.added + v.accruedFees;
        uint256 right = v.liquidity + v.swept + v.owed + v.deficit;
        assertApproxEqAbs(left, right, 3, "the Hub balance");
        // With fees accrued, available liquidity exceeds supplied minus drawn.
        if (v.accruedFees > 0) assertGt(v.liquidity + v.owed, v.added, "available is not added - owed");
    }

    // TEST-247 verifies: REQ-LENS-058, REQ-LENS-059
    function test_TEST_247_vaultTokenAssetHasNoLendSpokeAndAStrangerIsOther() public {
        HubAssetView memory v = lens.getHubAsset(aave.hub, vtAssetId);
        assertEq(v.underlying, vt, "the vault token");
        assertEq(v.lendSpoke, address(0), "no Lend Spoke");
        assertEq(v.priceUsd8, 0, "no Lend price");
        assertEq(uint8(_slice(v, aave.cdpSpoke).kind), uint8(SpokeKind.Cdp), "CDP");
        assertEq(_slice(v, aave.cdpSpoke).added, 100_000e6, "the supplied collateral");
        address stranger = makeAddr("stranger");
        _addSpoke(stranger, vtAssetId);
        v = lens.getHubAsset(aave.hub, vtAssetId);
        assertEq(uint8(_slice(v, stranger).kind), uint8(SpokeKind.Other), "another Spoke on a vault-token asset");
        _addSpoke(stranger, ghoAssetId);
        v = lens.getHubAsset(aave.hub, ghoAssetId);
        assertEq(uint8(_slice(v, stranger).kind), uint8(SpokeKind.Lend), "on a lend asset it counts as Lend");
        assertEq(v.lendSpoke, aave.lendSpoke, "the first Lend Spoke in the Hub's order prices it");
    }

    // TEST-247 verifies: REQ-LENS-043, REQ-LENS-059
    function test_TEST_247_exposureSlicesCarryTheNewFields() public {
        _borrow(aliceProxy, 5000e18);
        HubAssetExposureView memory x = lens.getHubAssetExposure(aave.hub, address(debt));
        HubAssetView memory v = lens.getHubAsset(aave.hub, ghoAssetId);
        assertEq(abi.encode(x.spokes), abi.encode(v.spokes), "one slice definition");
    }

    // TEST-247 verifies: REQ-LENS-058, REQ-LENS-060, REQ-LENS-006, REQ-LENS-021
    function test_TEST_247_hubAssetUnknownOrLocked() public {
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.UnknownHubAsset.selector, aave.hub, 99));
        lens.getHubAsset(aave.hub, 99);
        _holdLock();
        vm.expectRevert(ILensErrors.Locked.selector);
        lens.getHubAsset(aave.hub, ghoAssetId);
    }

    // TEST-247 verifies: REQ-LENS-058
    function test_TEST_247_deficitAndFeesShowInTheView() public {
        _borrow(aliceProxy, 40_000e18);
        _hubConfig(abi.encodeWithSignature("updateLiquidityFee(address,uint256,uint256)", aave.hub, ghoAssetId, 2000));
        vm.warp(block.timestamp + 365 days);
        HubAssetView memory v = lens.getHubAsset(aave.hub, ghoAssetId);
        assertGt(v.accruedFees, 0, "fees accrue");
        assertEq(v.accruedFees, ILensHubReads(aave.hub).getAssetAccruedFees(ghoAssetId), "accrued fees");
        assertEq(v.liquidityFeeBps, 2000, "fee");
        assertEq(
            v.supplyRateRay, v.drawnRateRay * v.owed * 8000 / (v.added * 1e4), "supply rate keeps 80 % of the growth"
        );
        // A reported deficit shows rounded up.
        vm.mockCall(
            aave.hub, abi.encodeWithSignature("getAssetDeficitRay(uint256)", ghoAssetId), abi.encode(5 * RAY + 1)
        );
        assertEq(lens.getHubAsset(aave.hub, ghoAssetId).deficit, 6, "rounded up");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-058
    function test_TEST_247_premiumCountsInOwedAndUtilization() public {
        // A collateral risk of 100 % makes every borrower pay a premium equal to the drawn interest.
        _spokeConfig(
            abi.encodeWithSignature("updateCollateralRisk(address,uint256,uint256)", aave.cdpSpoke, vtReserveId, 10_000)
        );
        _borrow(aliceProxy, 60_000e18);
        vm.warp(block.timestamp + 180 days);
        HubAssetView memory v = lens.getHubAsset(aave.hub, ghoAssetId);
        assertGt(v.premium, 0, "a premium accrued");
        assertEq(v.owed, v.drawn + v.premium, "owed = drawn + premium");
        assertEq(v.utilizationBps, v.owed * 1e4 / v.added, "utilization counts the premium");
        assertEq(v.supplyRateRay, v.drawnRateRay * v.owed / v.added, "no liquidity fee: the whole growth");
    }
}
