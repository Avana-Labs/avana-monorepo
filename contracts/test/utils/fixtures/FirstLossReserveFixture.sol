// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {FirstLossReserve} from "../../../src/coverage/first-loss-reserve/FirstLossReserve.sol";
import {IFirstLossReserve} from "../../../src/coverage/first-loss-reserve/IFirstLossReserve.sol";
import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {MockDebtAsset} from "../mocks/MockDebtAsset.sol";
import {
    AvanaFirstLossReserveFixture,
    CoverageHubSpokeConfig,
    ICoverageHubConfigurator
} from "./AvanaFirstLossReserveFixture.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

/// @title FirstLossReserveFixture
/// @notice The two loss layers of one `(Hub, GHO)` on the local Aave V4: Avana's First-Loss Reserve funded by Avana
/// Labs, and behind it the DAO Deficit Offset (the same contract, with the Avana layer as its constructor setting)
/// funded by the DAO treasury. Both are listed on the Hub with `drawCap = 0`, hold `HUB_DEFICIT_ELIMINATOR_ROLE`, allow
/// the CDP Spoke, and map `withdraw` to a role held with the 14-day execution delay.
abstract contract FirstLossReserveFixture is AvanaFirstLossReserveFixture {
    uint256 internal constant OFFSET_SIZE = 150_000e18;

    FirstLossReserve internal avanaLayer;
    FirstLossReserve internal daoOffset;

    function _deployLayers() internal {
        _deployAaveV4();
        hub = IAaveV4Hub(aave.hub);
        gho = new MockDebtAsset("Gho Token", "GHO", 18);
        ghoAssetId = _listDebtAsset(address(gho), 18);
        _supplyCreditLine(gho, ghoAssetId, CREDIT_LINE_GHO);
        avanaLayer = _deployLayer(address(0), "AvanaFirstLossReserve");
        daoOffset = _deployLayer(address(avanaLayer), "DaoDeficitOffset");
        _configure(avanaLayer, FIRST_LOSS_RESERVE_MINIMUM_GHO, avanaLabs);
        _configure(daoOffset, OFFSET_SIZE, daoTreasury);
    }

    /// @notice Deploys a layer and registers it as the DAO's listing payload does.
    function _deployLayer(
        address inFront,
        string memory label
    ) internal returns (FirstLossReserve layer) {
        layer = new FirstLossReserve(aave.hub, address(gho), ghoAssetId, aave.accessManager, inFront);
        vm.label(address(layer), label);
        uint40 maxCap = hub.MAX_ALLOWED_SPOKE_CAP();
        uint24 maxRp = hub.MAX_RISK_PREMIUM_THRESHOLD();
        vm.prank(aaveDao);
        ICoverageHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, address(layer), ghoAssetId, CoverageHubSpokeConfig(maxCap, 0, maxRp, true, false));
        _grantDeficitEliminator(address(layer));
        _grantLayerRoles(address(layer));
    }

    function _grantLayerRoles(
        address layer
    ) internal {
        bytes4[] memory coverage = new bytes4[](1);
        coverage[0] = IFirstLossReserve.coverDeficit.selector;
        bytes4[] memory admin = new bytes4[](2);
        admin[0] = IFirstLossReserve.setAllowedSpoke.selector;
        admin[1] = IFirstLossReserve.setMinimum.selector;
        bytes4[] memory withdraw = new bytes4[](1);
        withdraw[0] = IFirstLossReserve.withdraw.selector;
        IAccessManager manager = IAccessManager(aave.accessManager);
        vm.startPrank(aaveDao);
        manager.setTargetFunctionRole(layer, coverage, COVERAGE_ROLE);
        manager.setTargetFunctionRole(layer, admin, RESERVE_ADMIN_ROLE);
        manager.setTargetFunctionRole(layer, withdraw, WITHDRAW_ROLE);
        manager.grantRole(COVERAGE_ROLE, coverageCaller, 0);
        manager.grantRole(RESERVE_ADMIN_ROLE, aaveGovernanceExecutor, 0);
        manager.grantRole(WITHDRAW_ROLE, aaveGovernanceExecutor, FirstLossReserve(layer).WITHDRAWAL_DELAY());
        vm.stopPrank();
    }

    function _configure(
        FirstLossReserve layer,
        uint256 minimum,
        address funder
    ) internal {
        vm.startPrank(aaveGovernanceExecutor);
        layer.setAllowedSpoke(aave.cdpSpoke, true);
        layer.setMinimum(minimum);
        vm.stopPrank();
        _fundLayer(layer, funder, minimum);
    }

    function _fundLayer(
        FirstLossReserve layer,
        address funder,
        uint256 amount
    ) internal returns (uint256 shares) {
        gho.mint(funder, amount);
        vm.startPrank(funder);
        gho.approve(address(layer), amount);
        shares = layer.fund(amount);
        vm.stopPrank();
    }

    function _cover(
        FirstLossReserve layer,
        address spoke,
        uint256 maxAmount
    ) internal returns (uint256 covered) {
        vm.prank(coverageCaller);
        (, covered) = layer.coverDeficit(spoke, maxAmount);
    }

    /// @notice `ceil(deficitRay / RAY)` of `spoke`.
    function _deficit(
        address spoke
    ) internal view returns (uint256) {
        return (hub.getSpokeDeficitRay(ghoAssetId, spoke) + RAY - 1) / RAY;
    }
}
