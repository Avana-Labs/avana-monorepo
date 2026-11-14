// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaFirstLossReserve} from "../../src/coverage/first-loss-reserve/AvanaFirstLossReserve.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IMarketRegistryHubs} from "../../src/policy/market-registry/IMarketRegistryHubs.sol";
import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {AaveV4Fixture} from "../utils/fixtures/AaveV4Fixture.sol";
import {
    CollHubSpokeConfig,
    CollInterestRateData,
    ICollHubConfigurator
} from "../utils/fixtures/CollateralizationFixture.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {CollPoolToken} from "../utils/mocks/CollateralizationMocks.sol";

/// @title AvanaFirstLossReserveCrossHubLinesUnitTest
/// @notice Cross-Hub credit lines bounded by the funding Hub's first-loss capital (2.14 REQ-FLR-043), with a real
/// First-Loss Reserve on the real local Aave V4 Hub as the funding Hub's reserve for the asset: the MarketRegistry accepts
/// `crossHubLineTotal(fundingHub, a) ≤ fundedBalance()` of that First-Loss Reserve and refuses any raise above it with
/// `CrossHubCapExceeded(total, fundedBalance)`; funding the reserve raises the bound and a cut is always accepted.
/// Example of the spec: the reserve holds 250,000 USDC; a line bringing the total to 300,000 USDC reverts and 250,000
/// is accepted.
contract AvanaFirstLossReserveCrossHubLinesUnitTest is MarketRegistryFixture, AaveV4Fixture {
    CollPoolToken internal usdx;
    AvanaFirstLossReserve internal reserve;
    address internal funder = makeAddr("avanaLabsFunder");

    function setUp() public {
        _deployAaveV4();
        _setUpWorld();
        usdx = new CollPoolToken("USDC", 6);
        uint24 maxRp = IAaveV4Hub(aave.hub).MAX_RISK_PREMIUM_THRESHOLD();
        vm.startPrank(aaveDao);
        uint256 assetId = ICollHubConfigurator(aave.hubConfigurator)
            .addAssetWithDecimals(
                aave.hub,
                address(usdx),
                6,
                aave.treasurySpoke,
                0,
                aave.irStrategy,
                abi.encode(CollInterestRateData(9000, 0, 400, 6000))
            );
        reserve = new AvanaFirstLossReserve(aave.hub, address(usdx), assetId, aave.accessManager, 1_209_600);
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, address(reserve), assetId, CollHubSpokeConfig(10_000_000, 0, maxRp, true, false));
        vm.stopPrank();
        vm.startPrank(address(timelock));
        registry.recordHub(aave.hub, RiskTier.Correlated);
        registry.setAvanaFirstLossReserve(aave.hub, address(usdx), address(reserve));
        registry.setCrossHubLinesEnabled(true);
        vm.stopPrank();
        _fund(250_000e6);
    }

    function _fund(
        uint256 amount
    ) internal {
        usdx.mint(funder, amount);
        vm.startPrank(funder);
        usdx.approve(address(reserve), amount);
        reserve.fund(amount);
        vm.stopPrank();
    }

    function _line(
        uint256 cap
    ) internal {
        vm.prank(address(timelock));
        registry.setCrossHubLine(aave.hub, address(usdx), address(spoke), cap);
    }

    // TEST-273 verifies: REQ-FLR-043, REQ-MREG-009, Q-378
    function test_TEST_273_crossHubLinesBoundedByTheRealReserve() public {
        assertEq(reserve.fundedBalance(), 250_000e6, "the funding Hub's USDC reserve");
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.CrossHubCapExceeded.selector, 300_000e6, 250_000e6));
        registry.setCrossHubLine(aave.hub, address(usdx), address(spoke), 300_000e6);

        _line(250_000e6);
        assertEq(registry.crossHubLineTotal(aave.hub, address(usdx)), 250_000e6, "accepted at the funded balance");
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryHubs.CrossHubCapExceeded.selector, 250_000e6 + 1, 250_000e6)
        );
        registry.setCrossHubLine(aave.hub, address(usdx), address(spoke), 250_000e6 + 1);

        _fund(50_000e6);
        _line(300_000e6);
        assertEq(registry.crossHubLineTotal(aave.hub, address(usdx)), 300_000e6, "raised after a top-up");
        _line(100_000e6);
        assertEq(registry.crossHubLineTotal(aave.hub, address(usdx)), 100_000e6, "a cut is always accepted");
    }
}
