// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {Deployments} from "../utils/Deployments.sol";
import {
    GvDynamicReserveConfig,
    GvHubSpokeConfig,
    GvInterestRateData,
    GvLiquidationConfig,
    GvPrice,
    GvReserveConfig,
    GvToken,
    IGvHubConfigurator,
    IGvSpokeConfigurator
} from "./GoldenVectors.integration.t.sol";

/// @dev Spoke refresh entry points of aave-v4 a3ef63e (SPOKE_USER_POSITION_UPDATER_ROLE, held by the DAO).
interface IRptSpokeRefresh {
    function updateUserRiskPremium(
        address onBehalfOf
    ) external;
    function updateUserDynamicConfig(
        address onBehalfOf
    ) external;
}

/// @dev Hub views of aave-v4 a3ef63e this suite reads beyond `IAaveV4Hub`.
interface IRptHubViews {
    function getSpokeDrawnShares(
        uint256 assetId,
        address spoke
    ) external view returns (uint256);
    function getSpokePremiumData(
        uint256 assetId,
        address spoke
    ) external view returns (uint256 premiumShares, int256 premiumOffsetRay);
}

/// @title RiskPremiumThresholdIntegrationTest
/// @notice `Q-141` on the pinned Aave V4 Hub and the standard CDP Spoke Avana deploys: many accounts at the top
/// collateral risk (20 %), with `riskPremiumThreshold` at that risk plus the one-basis-point margin, run borrows,
/// interest, partial repays, a normal and a deficit liquidation and the DAO's refresh of every account, and every call
/// passes. With the threshold equal to the top risk (`Q-111`), the per-account premium-share rounding sums past the
/// Hub's bound and the Hub reverts `InvalidPremiumChange`.
/// @dev Local run on the release the DAO deploys; the fork run of the same sequence is the 5.1 row's fork part.
contract RiskPremiumThresholdIntegrationTest is Deployments {
    uint24 internal constant TOP_RISK = 2000;
    uint256 internal constant N_USERS = 40;

    GvToken internal debt;
    GvToken internal collA;
    GvToken internal collB;
    GvPrice internal priceA;
    GvPrice internal priceB;
    uint256 internal debtAssetId;
    uint256 internal debtReserve;
    uint256 internal reserveA;
    uint256 internal reserveB;
    address[] internal users;
    address internal liquidator = makeAddr("rptLiquidator");

    // TEST-111 verifies: REQ-HUB-030, REQ-HUB-089, Q-141
    // Sources: 5.1 TEST-111, MATH-AR-20 to MATH-AR-24, SYM-54
    function test_TEST_111_marginKeepsEveryActionLive() public {
        _setUp(TOP_RISK + 1);
        // Every account borrows an amount whose premium shares round up.
        for (uint256 i; i < N_USERS; ++i) {
            _borrow(users[i], 1000e18 + 5 * i + 1);
            _assertBound(TOP_RISK + 1);
        }
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(users[2]).riskPremium, TOP_RISK, "top risk in use");

        // Interest, then partial repays and further borrows on every debt reserve position.
        vm.warp(block.timestamp + 180 days);
        for (uint256 i; i < N_USERS; i += 2) {
            _repay(users[i], 333e18 + i + 3);
            _assertBound(TOP_RISK + 1);
        }
        vm.warp(block.timestamp + 45 days);
        for (uint256 i = 1; i < N_USERS; i += 2) {
            _borrow(users[i], 77e18 + 3 * i + 2);
            _assertBound(TOP_RISK + 1);
        }

        // Normal liquidation (account 0, collateral A) and deficit liquidation (account 1, collateral B).
        priceA.set(9e8);
        assertLt(IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(users[0]).healthFactor, 1e18, "account 0 liquidatable");
        uint256 debtBefore = IAaveV4Spoke(aave.cdpSpoke).getUserTotalDebt(debtReserve, users[0]);
        _liquidate(reserveA, users[0], 5000e18);
        uint256 debtAfter = IAaveV4Spoke(aave.cdpSpoke).getUserTotalDebt(debtReserve, users[0]);
        assertGt(debtAfter, 0, "partial liquidation");
        assertLt(debtAfter, debtBefore, "debt restored");
        _assertBound(TOP_RISK + 1);

        priceB.set(1e7);
        _liquidate(reserveB, users[1], 100_000e18);
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserTotalDebt(debtReserve, users[1]), 0, "debt moved to deficit");
        assertGt(IAaveV4Hub(aave.hub).getSpokeDeficitRay(debtAssetId, aave.cdpSpoke), 0, "deficit reported");
        _assertBound(TOP_RISK + 1);

        // The DAO's refresh payload over every account.
        vm.startPrank(aaveDao);
        for (uint256 i; i < N_USERS; ++i) {
            IRptSpokeRefresh(aave.cdpSpoke).updateUserRiskPremium(users[i]);
            IRptSpokeRefresh(aave.cdpSpoke).updateUserDynamicConfig(users[i]);
        }
        vm.stopPrank();
        _assertBound(TOP_RISK + 1);

        // Full repay by the remaining accounts still passes.
        for (uint256 i = 2; i < N_USERS; ++i) {
            _repay(users[i], type(uint256).max);
        }
        _assertBound(TOP_RISK + 1);
    }

    // TEST-111 verifies: REQ-HUB-089, Q-141
    // Sources: 5.1 TEST-111 (the original Q-111 setting reproduces the Hub revert)
    function test_TEST_111_thresholdAtTopRiskReverts() public {
        _setUp(TOP_RISK);
        _borrow(users[0], 1000e18 + 1);
        assertGt(
            IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(users[1]).totalCollateralValue, 0, "collateral in place"
        );
        vm.prank(users[1]);
        vm.expectRevert(bytes4(keccak256("InvalidPremiumChange()")));
        IAaveV4Spoke(aave.cdpSpoke).borrow(debtReserve, 1000e18 + 6, users[1]);
    }

    // ─── Helpers ───

    function _setUp(
        uint24 threshold
    ) internal {
        _deployAaveV4();
        bytes memory irData = abi.encode(GvInterestRateData(9000, 300, 400, 6000));
        debt = new GvToken("GHO", 18);
        collA = new GvToken("COLLA", 18);
        collB = new GvToken("COLLB", 18);
        priceA = new GvPrice(10e8);
        priceB = new GvPrice(10e8);
        uint256 lendReserve = _listDebt(threshold, irData);
        reserveA = _addCollateral(address(collA), address(priceA), irData);
        reserveB = _addCollateral(address(collB), address(priceB), irData);
        vm.prank(aaveDao);
        IGvSpokeConfigurator(aave.spokeConfigurator)
            .updateLiquidationConfig(aave.cdpSpoke, GvLiquidationConfig(1.05e18, 0.7e18, 2000));

        debt.mint(daoTreasury, 100_000_000e18);
        vm.startPrank(daoTreasury);
        debt.approve(aave.lendSpoke, 100_000_000e18);
        IAaveV4Spoke(aave.lendSpoke).supply(lendReserve, 100_000_000e18, daoTreasury);
        vm.stopPrank();

        for (uint256 i; i < N_USERS; ++i) {
            users.push(makeAddr(string.concat("rptUser", vm.toString(i))));
        }
        // Account 0: thin collateral A, liquidated on a 10 % fall; account 1: collateral B only, crashed to a deficit;
        // every other account: ample collateral A. All at the same top collateral risk.
        _supply(users[0], collA, reserveA, 1500e18);
        _supply(users[1], collB, reserveB, 10_000e18);
        for (uint256 i = 2; i < N_USERS; ++i) {
            _supply(users[i], collA, reserveA, 10_000e18);
        }
    }

    function _listDebt(
        uint24 threshold,
        bytes memory irData
    ) internal returns (uint256 lendReserve) {
        uint40 maxCap = IAaveV4Hub(aave.hub).MAX_ALLOWED_SPOKE_CAP();
        uint24 maxRp = IAaveV4Hub(aave.hub).MAX_RISK_PREMIUM_THRESHOLD();
        address one = address(new GvPrice(1e8));
        vm.startPrank(aaveDao);
        debtAssetId = IGvHubConfigurator(aave.hubConfigurator)
            .addAssetWithDecimals(aave.hub, address(debt), 18, aave.treasurySpoke, 1000, aave.irStrategy, irData);
        IGvHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, aave.lendSpoke, debtAssetId, GvHubSpokeConfig(maxCap, 0, maxRp, true, false));
        IGvHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, aave.cdpSpoke, debtAssetId, GvHubSpokeConfig(0, maxCap, threshold, true, false));
        lendReserve = _debtReserve(aave.lendSpoke, one);
        debtReserve = _debtReserve(aave.cdpSpoke, one);
        vm.stopPrank();
    }

    function _debtReserve(
        address spoke,
        address price
    ) internal returns (uint256) {
        return IGvSpokeConfigurator(aave.spokeConfigurator)
            .addReserve(
                spoke,
                aave.hub,
                debtAssetId,
                price,
                GvReserveConfig(0, false, false, true, false),
                GvDynamicReserveConfig(0, 10_000, 0)
            );
    }

    function _addCollateral(
        address coll,
        address price,
        bytes memory irData
    ) internal returns (uint256 reserveId) {
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        GvHubSpokeConfig memory cfg =
            GvHubSpokeConfig(hubView.MAX_ALLOWED_SPOKE_CAP(), 0, hubView.MAX_RISK_PREMIUM_THRESHOLD(), true, false);
        vm.startPrank(aaveDao);
        uint256 assetId = IGvHubConfigurator(aave.hubConfigurator)
            .addAssetWithDecimals(aave.hub, coll, 18, aave.treasurySpoke, 0, aave.irStrategy, irData);
        IGvHubConfigurator(aave.hubConfigurator).addSpoke(aave.hub, aave.cdpSpoke, assetId, cfg);
        reserveId = IGvSpokeConfigurator(aave.spokeConfigurator)
            .addReserve(
                aave.cdpSpoke,
                aave.hub,
                assetId,
                price,
                GvReserveConfig(TOP_RISK, false, false, false, false),
                GvDynamicReserveConfig(8000, 10_500, 0)
            );
        vm.stopPrank();
    }

    function _supply(
        address user,
        GvToken coll,
        uint256 reserveId,
        uint256 amount
    ) internal {
        coll.mint(user, amount);
        vm.startPrank(user);
        coll.approve(aave.cdpSpoke, amount);
        IAaveV4Spoke(aave.cdpSpoke).supply(reserveId, amount, user);
        IAaveV4Spoke(aave.cdpSpoke).setUsingAsCollateral(reserveId, true, user);
        vm.stopPrank();
    }

    function _borrow(
        address user,
        uint256 amount
    ) internal {
        // Account 0 borrows close to its capacity so a 10 % fall makes it liquidatable.
        if (user == users[0]) amount += 10_500e18;
        vm.prank(user);
        IAaveV4Spoke(aave.cdpSpoke).borrow(debtReserve, amount, user);
    }

    function _repay(
        address user,
        uint256 amount
    ) internal {
        uint256 owed = IAaveV4Spoke(aave.cdpSpoke).getUserTotalDebt(debtReserve, user);
        if (amount > owed) amount = owed;
        debt.mint(user, amount);
        vm.startPrank(user);
        debt.approve(aave.cdpSpoke, amount);
        IAaveV4Spoke(aave.cdpSpoke).repay(debtReserve, amount, user);
        vm.stopPrank();
    }

    function _liquidate(
        uint256 collReserve,
        address user,
        uint256 cover
    ) internal {
        debt.mint(liquidator, cover);
        vm.startPrank(liquidator);
        debt.approve(aave.cdpSpoke, cover);
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(collReserve, debtReserve, user, cover, false);
        vm.stopPrank();
    }

    /// @notice The Hub's bound on the CDP Spoke: premium shares at most `percentMulUp(drawnShares, threshold)`.
    function _assertBound(
        uint24 threshold
    ) internal view {
        uint256 drawn = IRptHubViews(aave.hub).getSpokeDrawnShares(debtAssetId, aave.cdpSpoke);
        (uint256 premium,) = IRptHubViews(aave.hub).getSpokePremiumData(debtAssetId, aave.cdpSpoke);
        assertLe(premium, (drawn * threshold + 9999) / 10_000, "premium shares within the threshold");
    }
}
