// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {HubAssetView} from "../../src/lens/lens/types/HubAssetView.sol";
import {CollPriceSource} from "../utils/fixtures/CollateralizationFixture.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensHubAssetPriceUnitTest
/// @notice The one USD price of a Hub asset is its Lend Spoke's oracle price: when the Lend Spoke and the CDP Spoke
/// price the asset differently, `getHubAsset` reports the Lend Spoke's, while the debt-reserve view keeps the CDP
/// Spoke's own price for its health checks.
/// forge-config: default.isolate = false
contract LensHubAssetPriceUnitTest is LensFixture {
    function setUp() public {
        _deployLens();
    }

    // TEST-247 verifies: REQ-LENS-058
    function test_TEST_247_priceIsTheLendSpokesOraclePrice() public {
        uint256 lendReserve = IAaveV4Spoke(aave.lendSpoke).getReserveId(aave.hub, ghoAssetId);
        CollPriceSource lendSource = new CollPriceSource(1.0003e8);
        _spokeConfig(
            abi.encodeWithSignature(
                "updateReservePriceSource(address,uint256,address)", aave.lendSpoke, lendReserve, address(lendSource)
            )
        );
        HubAssetView memory v = lens.getHubAsset(aave.hub, ghoAssetId);
        assertEq(v.lendSpoke, aave.lendSpoke, "the Lend Spoke");
        assertEq(v.priceUsd8, 1.0003e8, "its oracle's price");
        assertEq(lens.getDebtReserve(aave.cdpSpoke, debtReserveId).price, 1e8, "the CDP Spoke keeps its own");
        lendSource.set(0.9995e8);
        assertEq(lens.getHubAsset(aave.hub, ghoAssetId).priceUsd8, 0.9995e8, "read in the same block");
    }
}
