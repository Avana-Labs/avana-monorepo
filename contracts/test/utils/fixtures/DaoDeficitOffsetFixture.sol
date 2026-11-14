// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DaoDeficitOffset} from "../../../src/coverage/dao-deficit-offset/DaoDeficitOffset.sol";
import {AvanaFirstLossReserve} from "../../../src/coverage/first-loss-reserve/AvanaFirstLossReserve.sol";
import {MockDebtAsset} from "../mocks/MockDebtAsset.sol";
import {
    AvanaFirstLossReserveFixture,
    CoverageHubSpokeConfig,
    ICoverageHubConfigurator
} from "./AvanaFirstLossReserveFixture.sol";

/// @title DaoDeficitOffsetFixture
/// @notice The two loss layers of `Q-410` on the local Aave V4: for GHO and USDC on the Stable LP Hub, the Avana
/// Umbrella (First-Loss Reserve) of `AvanaFirstLossReserveFixture`, funded by Avana Labs, and behind it a DAO deficit offset
/// (`DaoDeficitOffset`) registered on the same asset with `drawCap = 0` and `addCap = MAX_ALLOWED_SPOKE_CAP`, holding
/// `HUB_DEFICIT_ELIMINATOR_ROLE`, mapped to the same `COVERAGE_ROLE` and `RESERVE_ADMIN_ROLE`, allowlisting the CDP
/// Spoke, with `firstLossReserveMinimum = daoDeficitOffset` and funded by the Aave DAO treasury to that size.
abstract contract DaoDeficitOffsetFixture is AvanaFirstLossReserveFixture {
    /// @notice `daoDeficitOffset` per asset (fixture values).
    uint256 internal constant DAO_OFFSET_GHO = 150_000e18;
    uint256 internal constant DAO_OFFSET_USDC = 75_000e6;

    DaoDeficitOffset internal ghoOffset;
    DaoDeficitOffset internal usdcOffset;

    function _deployLayers() internal {
        _deployCoverage();
        ghoOffset = _deployOffset(ghoCoverage, address(gho), ghoAssetId, "GhoDeficitOffset");
        usdcOffset = _deployOffset(usdcCoverage, address(usdc), usdcAssetId, "UsdcDeficitOffset");
        _configureOffset(ghoOffset, gho, DAO_OFFSET_GHO);
        _configureOffset(usdcOffset, usdc, DAO_OFFSET_USDC);
    }

    /// @notice Deploys a DAO deficit offset behind `layer` and registers it as the DAO's payload does (REQ-FLR-046).
    function _deployOffset(
        AvanaFirstLossReserve layer,
        address token,
        uint256 assetId,
        string memory label
    ) internal returns (DaoDeficitOffset offset) {
        offset = new DaoDeficitOffset(
            aave.hub, token, assetId, aave.accessManager, RESERVE_WITHDRAWAL_DELAY, address(layer)
        );
        vm.label(address(offset), label);
        uint40 maxCap = hub.MAX_ALLOWED_SPOKE_CAP();
        uint24 maxRp = hub.MAX_RISK_PREMIUM_THRESHOLD();
        vm.prank(aaveDao);
        ICoverageHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, address(offset), assetId, CoverageHubSpokeConfig(maxCap, 0, maxRp, true, false));
        _grantDeficitEliminator(address(offset));
        _grantCoverageRoles(address(offset));
    }

    /// @notice The DAO allowlists the CDP Spoke, sets the offset size and funds it from its treasury.
    function _configureOffset(
        DaoDeficitOffset offset,
        MockDebtAsset token,
        uint256 size
    ) internal {
        vm.startPrank(aaveGovernanceExecutor);
        offset.setAllowedBorrowSpoke(aave.cdpSpoke, true);
        offset.setFirstLossReserveMinimum(size);
        vm.stopPrank();
        _fund(offset, token, daoTreasury, size);
    }

    function _coverWith(
        AvanaFirstLossReserve cs,
        address spoke,
        uint256 maxAmount
    ) internal returns (uint256 covered) {
        vm.prank(coverageCaller);
        (, covered) = cs.coverDeficit(spoke, maxAmount);
    }

    /// @notice `ceil(deficitRay / RAY)` of `spoke` on `assetId`.
    function _deficitUnits(
        uint256 assetId,
        address spoke
    ) internal view returns (uint256) {
        return (hub.getSpokeDeficitRay(assetId, spoke) + RAY - 1) / RAY;
    }
}
