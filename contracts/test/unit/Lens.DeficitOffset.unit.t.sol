// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {HubAssetExposureView, SpokeDraw} from "../../src/lens/lens/types/HubAssetExposureView.sol";
import {HubAssetView} from "../../src/lens/lens/types/HubAssetView.sol";
import {SpokeKind} from "../../src/lens/lens/types/SpokeKind.sol";
import {TailCoverageView} from "../../src/lens/lens/types/TailCoverageView.sol";
import {CollHubSpokeConfig, ICollHubConfigurator} from "../utils/fixtures/CollateralizationFixture.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";
import {LensFirstLossLayerMock} from "../utils/mocks/LensMocks.sol";

/// @title LensDeficitOffsetUnitTest
/// @notice The second loss layer on the real Aave V4 Hub: a DAO deficit offset registered on the GHO asset behind the
/// Avana Umbrella. `uncoveredDeficit` subtracts both layers, the exposure and tail views name the offset and its added
/// assets, its slice is of kind DeficitOffset, and a Spoke whose `FIRST_LOSS_LAYER()` reverts, names another layer or
/// returns a malformed word is no offset.
/// forge-config: default.isolate = false
contract LensDeficitOffsetUnitTest is LensFixture {
    LensFirstLossLayerMock internal offset;

    function setUp() public {
        _deployLens();
        _setDrawCap(ghoAssetId, aave.cdpSpoke, 600_000);
        store.setCaps(MARKET_ID, 1_000_000e8, 20_000e8, 1e8);
        offset = new LensFirstLossLayerMock(address(ghoCov));
        uint40 maxCap = IAaveV4Hub(aave.hub).MAX_ALLOWED_SPOKE_CAP();
        vm.prank(aaveDao);
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, address(offset), ghoAssetId, CollHubSpokeConfig(maxCap, 0, 0, true, false));
    }

    function _mock(
        bytes memory data,
        uint256 value
    ) internal {
        vm.mockCall(aave.hub, data, abi.encode(value));
    }

    function _offsetFunded(
        uint256 amount
    ) internal {
        _mock(abi.encodeWithSignature("getSpokeAddedAssets(uint256,address)", ghoAssetId, address(offset)), amount);
    }

    function _deficits() internal {
        // Base units: deficits of 1,500,000.4 and 2,800,000 against 4,000,000 in the Avana Umbrella.
        _mock(abi.encodeWithSignature("getSpokeDeficitRay(uint256,address)", ghoAssetId, aave.cdpSpoke), 1_500_000.4e27);
        _mock(abi.encodeWithSignature("getSpokeDeficitRay(uint256,address)", ghoAssetId, aave.lendSpoke), 2_800_000e27);
        ghoCov.set(4_000_000, 100_000e18);
    }

    function _kindOf(
        SpokeDraw[] memory spokes,
        address spoke
    ) internal pure returns (SpokeKind) {
        for (uint256 i = 0; i < spokes.length; ++i) {
            if (spokes[i].spoke == spoke) return spokes[i].kind;
        }
        revert("no slice");
    }

    // TEST-247 verifies: REQ-LENS-042, REQ-FLR-046, Q-410
    function test_TEST_247_uncoveredDeficitSubtractsBothLayers() public {
        _deficits();
        _offsetFunded(0);
        assertEq(lens.uncoveredDeficit(aave.hub, address(debt)), 300_001, "an empty offset covers nothing");
        _offsetFunded(300_000);
        assertEq(lens.uncoveredDeficit(aave.hub, address(debt)), 1, "one unit short");
        _offsetFunded(300_001);
        assertEq(lens.uncoveredDeficit(aave.hub, address(debt)), 0, "the spec example: 0 with 300,001 in the offset");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-043, REQ-LENS-059, DEF-021
    function test_TEST_247_exposureNamesTheOffsetAndKeepsTheBoundOnTheUmbrella() public {
        _deficits();
        _offsetFunded(250_000);
        HubAssetExposureView memory v = lens.getHubAssetExposure(aave.hub, address(debt));
        assertEq(v.deficitOffset, address(offset), "the offset behind the Umbrella");
        assertEq(v.offsetFunded, 250_000, "its added assets");
        assertEq(v.fundedBalance, 4_000_000, "the Umbrella's balance alone");
        assertEq(v.uncovered, 50_001, "4,300,001 - 4,000,000 - 250,000");
        assertEq(uint8(_kindOf(v.spokes, address(offset))), uint8(SpokeKind.DeficitOffset), "slice kind");
        HubAssetView memory h = lens.getHubAsset(aave.hub, ghoAssetId);
        assertEq(uint8(_kindOf(h.spokes, address(offset))), uint8(SpokeKind.DeficitOffset), "same kind on getHubAsset");
        assertEq(h.lendSpoke, aave.lendSpoke, "the offset is not the Lend Spoke");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-034, SPEC-CAP-008
    function test_TEST_247_tailCoverageReportsTheOffsetBesideTheRatio() public {
        TailCoverageView memory before = lens.getTailCoverage(aave.hub, address(debt));
        _offsetFunded(70_000e18);
        TailCoverageView memory t = lens.getTailCoverage(aave.hub, address(debt));
        assertEq(t.deficitOffset, address(offset), "offset");
        assertEq(t.offsetFunded, 70_000e18, "offset funded");
        assertEq(t.funded, before.funded, "funded is the Umbrella's");
        assertEq(t.ratioBps, before.ratioBps, "the ratio measures the first loss layer");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-042, REQ-LENS-059
    function test_TEST_247_malformedOrOtherLayerIsNoOffset() public {
        _deficits();
        _offsetFunded(300_001);
        LensFirstLossLayerMock.Mode[3] memory bad = [
            LensFirstLossLayerMock.Mode.Revert,
            LensFirstLossLayerMock.Mode.DirtyWord,
            LensFirstLossLayerMock.Mode.LongReturn
        ];
        for (uint256 i = 0; i < 3; ++i) {
            offset.set(bad[i], address(ghoCov));
            HubAssetExposureView memory v = lens.getHubAssetExposure(aave.hub, address(debt));
            assertEq(v.deficitOffset, address(0), "no match");
            assertEq(v.uncovered, 300_001, "nothing subtracted");
            assertEq(uint8(_kindOf(v.spokes, address(offset))), uint8(SpokeKind.Lend), "classed as any other Spoke");
        }
        offset.set(LensFirstLossLayerMock.Mode.Address, makeAddr("anotherUmbrella"));
        assertEq(lens.uncoveredDeficit(aave.hub, address(debt)), 300_001, "behind another layer: not this pair's");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-042
    function test_TEST_247_noUmbrellaMeansNoOffset() public {
        _deficits();
        _offsetFunded(300_001);
        reg.setAvanaFirstLossReserve(aave.hub, address(debt), address(0));
        HubAssetExposureView memory v = lens.getHubAssetExposure(aave.hub, address(debt));
        assertEq(v.deficitOffset, address(0), "nothing to stand behind");
        assertEq(v.offsetFunded, 0, "0");
        assertEq(v.uncovered, 4_300_001, "every deficit uncovered");
        vm.clearMockedCalls();
    }

    function _register(
        address spoke
    ) internal {
        uint40 maxCap = IAaveV4Hub(aave.hub).MAX_ALLOWED_SPOKE_CAP();
        vm.prank(aaveDao);
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, spoke, ghoAssetId, CollHubSpokeConfig(maxCap, 0, 0, true, false));
    }

    // TEST-247 verifies: REQ-LENS-042, REQ-LENS-043
    function test_TEST_247_everyMatchingSpokeCountsAndTheFirstIsNamed() public {
        LensFirstLossLayerMock second = new LensFirstLossLayerMock(address(ghoCov));
        _register(address(second));
        _deficits();
        _offsetFunded(100_000);
        _mock(abi.encodeWithSignature("getSpokeAddedAssets(uint256,address)", ghoAssetId, address(second)), 200_001);
        HubAssetExposureView memory v = lens.getHubAssetExposure(aave.hub, address(debt));
        assertEq(v.deficitOffset, address(offset), "the first in the Hub's order");
        assertEq(v.offsetFunded, 300_001, "both offsets' added assets");
        assertEq(v.uncovered, 0, "together they cover the residual");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-042, REQ-LENS-059
    function test_TEST_247_aSpokeWithoutCodeIsNoOffset() public {
        address bare = makeAddr("bareSpoke");
        _register(bare);
        _deficits();
        _mock(abi.encodeWithSignature("getSpokeAddedAssets(uint256,address)", ghoAssetId, bare), 300_001);
        offset.set(LensFirstLossLayerMock.Mode.Revert, address(ghoCov));
        HubAssetExposureView memory v = lens.getHubAssetExposure(aave.hub, address(debt));
        assertEq(v.offsetFunded, 0, "an empty return is no match");
        assertEq(v.uncovered, 300_001, "nothing subtracted");
        assertEq(uint8(_kindOf(v.spokes, bare)), uint8(SpokeKind.Lend), "any other Spoke");
        vm.clearMockedCalls();
    }
}
