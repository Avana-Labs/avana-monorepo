// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaFirstLossReserve} from "../../src/coverage/first-loss-reserve/AvanaFirstLossReserve.sol";
import {IntegrationFlows} from "../utils/fixtures/IntegrationFlows.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

/// @title LPVaultSwapHostileDeficitIntegrationTest
/// @notice `TEST-211` of the LPVaultSwap hostile suite: each First-Loss Reserve covers only deficits of its own
/// `(Hub, asset)`, on the real AvanaFirstLossReserve and Aave V4 Hub.
/// @dev Kept on the stand-in fixture: a deficit needs collateral worth less than the debt, which the real stack's
/// USDC/USDT vault token (CF 30 %, prices held inside the $0.90-$1.02 USD band) cannot reach; the rest of the suite is
/// on the real stack in `LPVaultSwap.Hostile`.
/// forge-config: default.isolate = false
contract LPVaultSwapHostileDeficitIntegrationTest is IntegrationFlows {
    function setUp() public {
        _deployIntegration();
    }

    /// @notice Each First-Loss Reserve covers only deficits of its own `(Hub, asset)`: an account owing USDC and GHO is
    /// liquidated to exhaustion so the CDP Spoke records a deficit in both assets; the USDC First-Loss Reserve's cover lowers
    /// the USDC deficit and leaves the GHO deficit exactly unchanged.
    // TEST-211 verifies: SPEC-FLR-001, INV-079, ATTACK-173
    function test_TEST_211_coverageReducesOnlyItsOwnAssetsDeficit() public {
        (address p,) = _openAccount(carol, MARKET_ID, 10_000e6, 9000e6, 250_000_000);
        _setPrice(MARKET_ID, 250_000_000);
        _borrowVia(carol, MARKET_ID, debtReserveId, 5000e18);
        _setPrice(MARKET_ID, 30_000_000);
        _liquidateAs(keeper, _liqParams(p, MARKET_ID, usdcReserveId, 9000e6));
        IHubDeficitView h = IHubDeficitView(aave.hub);
        uint256 usdcDeficit = h.getSpokeDeficitRay(usdcAssetId, aave.cdpSpoke);
        uint256 ghoDeficit = h.getSpokeDeficitRay(ghoAssetId, aave.cdpSpoke);
        assertGt(usdcDeficit, 0, "USDC deficit recorded");
        assertGt(ghoDeficit, 0, "GHO deficit recorded");
        _enableCover(address(usdcCoverage));
        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(usdcCoverage), 1_000_000e6);
        usdcCoverage.fund(1_000_000e6);
        vm.prank(coverageCaller);
        (, uint256 covered) = usdcCoverage.coverDeficit(aave.cdpSpoke, type(uint256).max);
        assertGt(covered, 0, "USDC deficit covered");
        assertEq(h.getSpokeDeficitRay(usdcAssetId, aave.cdpSpoke), 0, "USDC deficit cleared");
        assertEq(h.getSpokeDeficitRay(ghoAssetId, aave.cdpSpoke), ghoDeficit, "GHO deficit unchanged");
    }

    function _enableCover(
        address cs
    ) internal {
        bytes4[] memory cover = new bytes4[](1);
        cover[0] = AvanaFirstLossReserve.coverDeficit.selector;
        bytes4[] memory admin = new bytes4[](1);
        admin[0] = AvanaFirstLossReserve.setAllowedBorrowSpoke.selector;
        IAccessManager m = IAccessManager(aave.accessManager);
        vm.startPrank(aaveDao);
        m.setTargetFunctionRole(cs, cover, 500);
        m.setTargetFunctionRole(cs, admin, 501);
        m.grantRole(500, coverageCaller, 0);
        m.grantRole(501, aaveGovernanceExecutor, 0);
        vm.stopPrank();
        vm.prank(aaveGovernanceExecutor);
        AvanaFirstLossReserve(cs).setAllowedBorrowSpoke(aave.cdpSpoke, true);
    }
}

interface IHubDeficitView {
    function getSpokeDeficitRay(
        uint256 assetId,
        address spoke
    ) external view returns (uint256);
}
