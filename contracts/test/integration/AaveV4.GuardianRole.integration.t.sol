// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveGuardianRole} from "../../script/deploy/lib/AaveGuardianRole.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {AaveV4Fixture} from "../utils/fixtures/AaveV4Fixture.sol";
import {
    CollHubSpokeConfig,
    CollInterestRateData,
    CollPriceSource,
    CollSpokeDynamicReserveConfig,
    CollSpokeReserveConfig,
    ICollHubConfigurator,
    ICollSpokeConfigurator
} from "../utils/fixtures/CollateralizationFixture.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";

/// @notice The AccessManager calls the Guardian grant makes (OpenZeppelin AccessManager, as Aave V4 uses it).
interface IGuardianAccessManager {
    function labelRole(
        uint64 roleId,
        string calldata label
    ) external;
    function setTargetFunctionRole(
        address target,
        bytes4[] calldata selectors,
        uint64 roleId
    ) external;
    function grantRole(
        uint64 roleId,
        address account,
        uint32 executionDelay
    ) external;
    function hasRole(
        uint64 roleId,
        address account
    ) external view returns (bool isMember, uint32 executionDelay);
    function canCall(
        address caller,
        address target,
        bytes4 selector
    ) external view returns (bool immediate, uint32 delay);
}

interface IGuardianSpokeConfigurator {
    function freezeReserve(
        address spoke,
        uint256 reserveId
    ) external;
    function pauseReserve(
        address spoke,
        uint256 reserveId
    ) external;
    function updateFrozen(
        address spoke,
        uint256 reserveId,
        bool frozen
    ) external;
    function updatePaused(
        address spoke,
        uint256 reserveId,
        bool paused
    ) external;
}

/// @title AaveV4GuardianRoleIntegrationTest
/// @notice REQ-ACCESS-070 on the pinned Aave V4 release: the deployment AIP's Guardian grant (06_AaveDeploymentPayload,
/// `AaveGuardianRole`) lets the Aave Protocol Guardian freeze and pause a reserve through the SpokeConfigurator and
/// call nothing else, while the Domain Admin keeps both. The grant's calls are applied here as the AIP applies them.
/// forge-config: default.isolate = false
contract AaveV4GuardianRoleIntegrationTest is AaveV4Fixture {
    uint64 internal constant ROLE = 502;
    address internal guardian = makeAddr("aaveProtocolGuardian");
    address internal lender = makeAddr("lender");
    PayoutToken internal usdc;
    uint256 internal reserveId;

    /// @dev Every restricted selector of the pinned SpokeConfigurator (aave-v4 a3ef63e), from its compiled ABI.
    bytes4[23] internal configuratorSelectors = [
        bytes4(0xdf517545), // addCollateralFactor
        0xcb51c394, // addDynamicReserveConfig
        0x063c7dc0, // addLiquidationFee
        0x710bc180, // addMaxLiquidationBonus
        0x727ae397, // addReserve
        0x99b44258, // freezeAllReserves
        0x7492b5ec, // freezeReserve
        0x6a8b9a27, // pauseAllReserves
        0x36f1dfa0, // pauseReserve
        0x46bfdc72, // updateBorrowable
        0x092622b7, // updateCollateralFactor
        0xf165fdea, // updateCollateralRisk
        0x404f0b2c, // updateDynamicReserveConfig
        0x3a84f85a, // updateFrozen
        0xde3487b8, // updateHealthFactorForMaxBonus
        0x579b47eb, // updateLiquidationBonusFactor
        0xd15916be, // updateLiquidationConfig
        0xfd19d8f7, // updateLiquidationFee
        0x98e7856f, // updateLiquidationTargetHealthFactor
        0x3b0beccf, // updateMaxLiquidationBonus
        0x5f42a73b, // updatePaused
        0x152ef832, // updatePositionManager
        0x722c65ee // updateReceiveSharesEnabled
    ];
    /// @dev Aave V4's roles (aave-v4 Roles.sol): the Guardian holds none of them.
    uint64[10] internal aaveRoles = [uint64(0), 100, 101, 102, 103, 200, 300, 301, 302, 400];

    function setUp() public {
        _deployAaveV4();
        usdc = new PayoutToken("USDC", 6);
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        vm.startPrank(aaveDao);
        uint256 assetId = ICollHubConfigurator(aave.hubConfigurator)
            .addAssetWithDecimals(
                aave.hub,
                address(usdc),
                6,
                aave.treasurySpoke,
                0,
                aave.irStrategy,
                abi.encode(CollInterestRateData(9000, 0, 400, 6000))
            );
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(
                aave.hub,
                aave.lendSpoke,
                assetId,
                CollHubSpokeConfig(
                    hubView.MAX_ALLOWED_SPOKE_CAP(), 0, hubView.MAX_RISK_PREMIUM_THRESHOLD(), true, false
                )
            );
        reserveId = ICollSpokeConfigurator(aave.spokeConfigurator)
            .addReserve(
                aave.lendSpoke,
                aave.hub,
                assetId,
                address(new CollPriceSource(1e8)),
                CollSpokeReserveConfig(0, false, false, true, false),
                CollSpokeDynamicReserveConfig(0, 10_000, 0)
            );
        // The grant, as the deployment AIP makes it through the config engine.
        IGuardianAccessManager am = IGuardianAccessManager(aave.accessManager);
        am.labelRole(ROLE, AaveGuardianRole.LABEL);
        am.setTargetFunctionRole(aave.spokeConfigurator, AaveGuardianRole.selectors(), ROLE);
        am.grantRole(ROLE, guardian, 0);
        am.grantRole(ROLE, aaveDao, 0);
        vm.stopPrank();
        usdc.mint(lender, 2e12);
        vm.prank(lender);
        usdc.approve(aave.lendSpoke, type(uint256).max);
    }

    function test_selectorsAreTheOneWaySetters() public pure {
        bytes4[] memory s = AaveGuardianRole.selectors();
        assertEq(s.length, 2);
        assertEq(s[0], IGuardianSpokeConfigurator.freezeReserve.selector);
        assertEq(s[1], IGuardianSpokeConfigurator.pauseReserve.selector);
    }

    /// @notice The Guardian may call `freezeReserve` and `pauseReserve`, and no other SpokeConfigurator selector.
    function test_guardianCallsOnlyFreezeAndPause() public view {
        IGuardianAccessManager am = IGuardianAccessManager(aave.accessManager);
        for (uint256 i = 0; i < configuratorSelectors.length; ++i) {
            bytes4 s = configuratorSelectors[i];
            (bool can,) = am.canCall(guardian, aave.spokeConfigurator, s);
            bool allowed = s == IGuardianSpokeConfigurator.freezeReserve.selector
                || s == IGuardianSpokeConfigurator.pauseReserve.selector;
            assertEq(can, allowed, "Guardian access to a SpokeConfigurator selector");
        }
        for (uint256 i = 0; i < aaveRoles.length; ++i) {
            (bool member,) = am.hasRole(aaveRoles[i], guardian);
            assertFalse(member, "Guardian holds an Aave V4 role");
        }
        (bool m,) = am.hasRole(ROLE, guardian);
        assertTrue(m);
    }

    /// @notice The Domain Admin keeps both, through the new role.
    function test_domainAdminKeepsFreezeAndPause() public view {
        IGuardianAccessManager am = IGuardianAccessManager(aave.accessManager);
        (bool f,) = am.canCall(aaveDao, aave.spokeConfigurator, IGuardianSpokeConfigurator.freezeReserve.selector);
        (bool p,) = am.canCall(aaveDao, aave.spokeConfigurator, IGuardianSpokeConfigurator.pauseReserve.selector);
        (bool u,) = am.canCall(aaveDao, aave.spokeConfigurator, IGuardianSpokeConfigurator.updateFrozen.selector);
        assertTrue(f && p && u);
    }

    /// @notice A freeze stops new supply and keeps withdrawals; the Guardian cannot undo it.
    function test_guardianFreezesOneWay() public {
        vm.prank(lender);
        IAaveV4Spoke(aave.lendSpoke).supply(reserveId, 1e12, lender);

        vm.prank(guardian);
        IGuardianSpokeConfigurator(aave.spokeConfigurator).freezeReserve(aave.lendSpoke, reserveId);

        vm.prank(lender);
        vm.expectRevert();
        IAaveV4Spoke(aave.lendSpoke).supply(reserveId, 1e12, lender);
        vm.prank(lender);
        IAaveV4Spoke(aave.lendSpoke).withdraw(reserveId, 1e12, lender);

        vm.prank(guardian);
        vm.expectRevert();
        IGuardianSpokeConfigurator(aave.spokeConfigurator).updateFrozen(aave.lendSpoke, reserveId, false);
    }

    /// @notice A pause stops the reserve; the Guardian cannot undo it.
    function test_guardianPausesOneWay() public {
        vm.prank(guardian);
        IGuardianSpokeConfigurator(aave.spokeConfigurator).pauseReserve(aave.lendSpoke, reserveId);

        vm.prank(lender);
        vm.expectRevert();
        IAaveV4Spoke(aave.lendSpoke).supply(reserveId, 1e12, lender);

        vm.prank(guardian);
        vm.expectRevert();
        IGuardianSpokeConfigurator(aave.spokeConfigurator).updatePaused(aave.lendSpoke, reserveId, false);
    }

    /// @notice Anyone else is refused.
    function test_strangerCannotFreeze() public {
        vm.prank(lender);
        vm.expectRevert();
        IGuardianSpokeConfigurator(aave.spokeConfigurator).freezeReserve(aave.lendSpoke, reserveId);
    }
}
