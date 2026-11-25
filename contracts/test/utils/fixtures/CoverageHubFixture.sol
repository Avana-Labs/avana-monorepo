// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../../src/dependencies/aave/IAaveV4Hub.sol";
import {MockDebtAsset} from "../mocks/MockDebtAsset.sol";
import {AaveV4Fixture} from "./AaveV4Fixture.sol";

/// @dev Hub `SpokeConfig` of aave-v4 a3ef63e (`addCap` and `drawCap` in whole tokens).
struct CoverageHubSpokeConfig {
    uint40 addCap;
    uint40 drawCap;
    uint24 riskPremiumThreshold;
    bool active;
    bool halted;
}

/// @dev `AssetInterestRateStrategy.InterestRateData` of aave-v4 a3ef63e.
struct CoverageInterestRateData {
    uint16 optimalUsageRatio;
    uint32 baseDrawnRate;
    uint32 rateGrowthBeforeOptimal;
    uint32 rateGrowthAfterOptimal;
}

/// @dev The HubConfigurator calls the fixture makes as the Aave DAO.
interface ICoverageHubConfigurator {
    function addAssetWithDecimals(
        address hub,
        address underlying,
        uint8 decimals,
        address feeReceiver,
        uint256 liquidityFee,
        address irStrategy,
        bytes calldata irData
    ) external returns (uint256);
    function addSpoke(
        address hub,
        address spoke,
        uint256 assetId,
        CoverageHubSpokeConfig calldata config
    ) external;
    function updateSpokeActive(
        address hub,
        uint256 assetId,
        address spoke,
        bool active
    ) external;
    function updateSpokeHalted(
        address hub,
        uint256 assetId,
        address spoke,
        bool halted
    ) external;
    function updateSpokeAddCap(
        address hub,
        uint256 assetId,
        address spoke,
        uint256 addCap
    ) external;
}

/// @dev The Spoke-side Hub calls the fixture makes as a pranked Spoke to lend and to record deficits.
interface ICoverageHubSpokeCalls {
    function draw(
        uint256 assetId,
        uint256 amount,
        address to
    ) external returns (uint256);
    function reportDeficit(
        uint256 assetId,
        uint256 drawnAmount,
        IAaveV4Hub.PremiumDelta calldata premiumDelta
    ) external returns (uint256, uint256);
}

/// @title CoverageHubFixture
/// @notice GHO (18 decimals) listed on the local Aave V4 Stable LP Hub with a Lend Spoke credit line, the CDP Spoke
/// drawing it and a second drawing Spoke that is never allowlisted; deficits are recorded by the real Hub.
/// @dev Roles live in the Aave DAO's AccessManager. The role IDs are fixture values in the 500 range, outside Aave's
/// Hub, Spoke and configurator ranges; the DAO's payload fixes the deployed ones. A drawing Spoke is pranked to `draw`
/// and then `reportDeficit`, the two calls a liquidation that leaves no collateral makes.
abstract contract CoverageHubFixture is AaveV4Fixture {
    uint64 internal constant COVERAGE_ROLE = 500;
    uint64 internal constant RESERVE_ADMIN_ROLE = 501;
    uint64 internal constant WITHDRAW_ROLE = 503;

    uint40 internal constant DRAW_CAP = 2_000_000;

    MockDebtAsset internal gho;
    uint256 internal ghoAssetId;
    IAaveV4Hub internal hub;

    address internal otherSpoke = makeAddr("otherCdpSpoke");

    /// @notice Lists `token` on the Hub with the Lend Spoke supplying it and both CDP Spokes drawing it.
    function _listDebtAsset(
        address token,
        uint8 decimals
    ) internal returns (uint256 assetId) {
        uint40 maxCap = hub.MAX_ALLOWED_SPOKE_CAP();
        uint24 maxRp = hub.MAX_RISK_PREMIUM_THRESHOLD();
        ICoverageHubConfigurator cfg = ICoverageHubConfigurator(aave.hubConfigurator);
        vm.startPrank(aaveDao);
        assetId = cfg.addAssetWithDecimals(
            aave.hub,
            token,
            decimals,
            aave.treasurySpoke,
            0,
            aave.irStrategy,
            abi.encode(CoverageInterestRateData(9000, 0, 400, 6000))
        );
        cfg.addSpoke(aave.hub, aave.lendSpoke, assetId, CoverageHubSpokeConfig(maxCap, 0, maxRp, true, false));
        cfg.addSpoke(aave.hub, aave.cdpSpoke, assetId, CoverageHubSpokeConfig(0, DRAW_CAP, maxRp, true, false));
        cfg.addSpoke(aave.hub, otherSpoke, assetId, CoverageHubSpokeConfig(0, DRAW_CAP, maxRp, true, false));
        vm.stopPrank();
    }

    /// @notice The DAO treasury's credit line, added through the Lend Spoke (pranked as the Hub sees it).
    function _supplyCreditLine(
        MockDebtAsset token,
        uint256 assetId,
        uint256 amount
    ) internal {
        token.mint(aave.hub, amount);
        vm.prank(aave.lendSpoke);
        hub.add(assetId, amount);
    }

    /// @notice Records a deficit of `amount` on `spoke`: the Spoke draws `amount` and reports it all as a deficit.
    function _reportDeficit(
        uint256 assetId,
        address spoke,
        uint256 amount
    ) internal returns (uint256 deficitRay) {
        vm.startPrank(spoke);
        ICoverageHubSpokeCalls(aave.hub).draw(assetId, amount, spoke);
        ICoverageHubSpokeCalls(aave.hub).reportDeficit(assetId, amount, IAaveV4Hub.PremiumDelta(0, 0, 0));
        vm.stopPrank();
        deficitRay = hub.getSpokeDeficitRay(assetId, spoke);
    }

    /// @notice Draws `amount` on `spoke` as ordinary debt, so interest accrues to every added share.
    function _draw(
        uint256 assetId,
        address spoke,
        uint256 amount
    ) internal {
        vm.prank(spoke);
        ICoverageHubSpokeCalls(aave.hub).draw(assetId, amount, spoke);
    }

    function _setHalted(
        uint256 assetId,
        address spoke,
        bool halted
    ) internal {
        vm.prank(aaveDao);
        ICoverageHubConfigurator(aave.hubConfigurator).updateSpokeHalted(aave.hub, assetId, spoke, halted);
    }

    function _setActive(
        uint256 assetId,
        address spoke,
        bool active
    ) internal {
        vm.prank(aaveDao);
        ICoverageHubConfigurator(aave.hubConfigurator).updateSpokeActive(aave.hub, assetId, spoke, active);
    }

    /// @notice `ceil(x × (S + 1e6) / (A + 1e6))`, the Hub's share burn for `x` asset units (SPEC-FLR-001, -003).
    function _sharesUp(
        uint256 assetId,
        uint256 x
    ) internal view returns (uint256) {
        uint256 s = hub.getAddedShares(assetId) + 1e6;
        uint256 a = hub.getAddedAssets(assetId) + 1e6;
        return (x * s + a - 1) / a;
    }
}
