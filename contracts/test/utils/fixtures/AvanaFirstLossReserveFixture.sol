// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaFirstLossReserve} from "../../../src/coverage/first-loss-reserve/AvanaFirstLossReserve.sol";
import {IAvanaFirstLossReserve} from "../../../src/coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {IAvanaFirstLossReserveAdmin} from "../../../src/coverage/first-loss-reserve/IAvanaFirstLossReserveAdmin.sol";
import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {MockDebtAsset} from "../mocks/MockDebtAsset.sol";
import {AaveV4Fixture} from "./AaveV4Fixture.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

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

/// @title AvanaFirstLossReserveFixture
/// @notice The multi-asset coverage setup of 3.1 step 5 on the local Aave V4: GHO (18 decimals) and USDC (6 decimals)
/// listed on the Stable LP Hub, each with a Lend Spoke credit line, the CDP Spoke "Uniswap v3 Stable" drawing it, a
/// second drawing Spoke that is never allowlisted, and its own First-Loss Reserve registered on its asset with
/// `drawCap = 0`, holding `HUB_DEFICIT_ELIMINATOR_ROLE`, allowlisting the CDP Spoke and funded by Avana Labs to its
/// minimum.
/// @dev Roles live in the Aave DAO's AccessManager: `coverDeficit` maps to `COVERAGE_ROLE` (held by `coverageCaller`)
/// and the `IAvanaFirstLossReserveAdmin` functions to `RESERVE_ADMIN_ROLE` (held by `aaveGovernanceExecutor`). The role IDs
/// are fixture values in the 500 range, outside Aave's Hub, Spoke and configurator ranges; the DAO's payload fixes
/// the deployed ones. Deficits are recorded by the real Hub: a drawing Spoke is pranked to `draw` and then
/// `reportDeficit`, the two calls a liquidation that leaves no collateral makes.
abstract contract AvanaFirstLossReserveFixture is AaveV4Fixture {
    uint64 internal constant COVERAGE_ROLE = 500;
    uint64 internal constant RESERVE_ADMIN_ROLE = 501;
    uint256 internal constant RESERVE_WITHDRAWAL_DELAY = 1_209_600;

    /// @notice `firstLossReserveAddCap` per asset, whole tokens (fixture values).
    uint40 internal constant ADD_CAP_GHO = 1_000_000;
    uint40 internal constant ADD_CAP_USDC = 1_000_000;
    /// @notice Fixture USDC minimum and credit line (6 decimals).
    uint256 internal constant FIRST_LOSS_RESERVE_MINIMUM_USDC = 50_000e6;
    uint256 internal constant CREDIT_LINE_USDC = 2_000_000e6;
    /// @notice `drawCap` of each drawing Spoke, whole tokens.
    uint40 internal constant DRAW_CAP = 2_000_000;

    MockDebtAsset internal gho;
    MockDebtAsset internal usdc;
    uint256 internal ghoAssetId;
    uint256 internal usdcAssetId;
    AvanaFirstLossReserve internal ghoCoverage;
    AvanaFirstLossReserve internal usdcCoverage;
    IAaveV4Hub internal hub;

    /// @notice A second CDP Spoke drawing both assets, never on any allowlist.
    address internal otherSpoke = makeAddr("otherCdpSpoke");

    function _deployCoverage() internal {
        _deployAaveV4();
        hub = IAaveV4Hub(aave.hub);
        gho = new MockDebtAsset("Gho Token", "GHO", 18);
        usdc = new MockDebtAsset("USD Coin", "USDC", 6);
        vm.label(address(gho), "GHO");
        vm.label(address(usdc), "USDC");
        ghoAssetId = _listDebtAsset(address(gho), 18);
        usdcAssetId = _listDebtAsset(address(usdc), 6);
        _supplyCreditLine(gho, ghoAssetId, CREDIT_LINE_GHO);
        _supplyCreditLine(usdc, usdcAssetId, CREDIT_LINE_USDC);
        ghoCoverage = _deployAvanaFirstLossReserve(address(gho), ghoAssetId, ADD_CAP_GHO, "GhoAvanaFirstLossReserve");
        usdcCoverage =
            _deployAvanaFirstLossReserve(address(usdc), usdcAssetId, ADD_CAP_USDC, "UsdcAvanaFirstLossReserve");
        _configureAndFund(ghoCoverage, gho, FIRST_LOSS_RESERVE_MINIMUM_GHO);
        _configureAndFund(usdcCoverage, usdc, FIRST_LOSS_RESERVE_MINIMUM_USDC);
    }

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

    /// @notice Deploys a First-Loss Reserve and registers it as the DAO's listing payload does (REQ-FLR-007).
    function _deployAvanaFirstLossReserve(
        address token,
        uint256 assetId,
        uint40 addCap,
        string memory label
    ) internal returns (AvanaFirstLossReserve cs) {
        cs = new AvanaFirstLossReserve(aave.hub, token, assetId, aave.accessManager, RESERVE_WITHDRAWAL_DELAY);
        vm.label(address(cs), label);
        uint24 maxRp = hub.MAX_RISK_PREMIUM_THRESHOLD();
        vm.prank(aaveDao);
        ICoverageHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, address(cs), assetId, CoverageHubSpokeConfig(addCap, 0, maxRp, true, false));
        _grantDeficitEliminator(address(cs));
        _grantCoverageRoles(address(cs));
    }

    /// @notice Maps the First-Loss Reserve's selectors to its two roles and grants them.
    function _grantCoverageRoles(
        address cs
    ) internal {
        bytes4[] memory coverage = new bytes4[](1);
        coverage[0] = IAvanaFirstLossReserve.coverDeficit.selector;
        bytes4[] memory admin = new bytes4[](5);
        admin[0] = IAvanaFirstLossReserveAdmin.setAllowedBorrowSpoke.selector;
        admin[1] = IAvanaFirstLossReserveAdmin.setFirstLossReserveMinimum.selector;
        admin[2] = IAvanaFirstLossReserveAdmin.requestWithdrawal.selector;
        admin[3] = IAvanaFirstLossReserveAdmin.cancelWithdrawal.selector;
        admin[4] = IAvanaFirstLossReserveAdmin.executeWithdrawal.selector;
        IAccessManager manager = IAccessManager(aave.accessManager);
        vm.startPrank(aaveDao);
        manager.setTargetFunctionRole(cs, coverage, COVERAGE_ROLE);
        manager.setTargetFunctionRole(cs, admin, RESERVE_ADMIN_ROLE);
        manager.grantRole(COVERAGE_ROLE, coverageCaller, 0);
        manager.grantRole(RESERVE_ADMIN_ROLE, aaveGovernanceExecutor, 0);
        vm.stopPrank();
    }

    /// @notice The DAO allowlists the CDP Spoke and sets the minimum; Avana Labs funds the minimum.
    function _configureAndFund(
        AvanaFirstLossReserve cs,
        MockDebtAsset token,
        uint256 minimum
    ) internal {
        vm.startPrank(aaveGovernanceExecutor);
        cs.setAllowedBorrowSpoke(aave.cdpSpoke, true);
        cs.setFirstLossReserveMinimum(minimum);
        vm.stopPrank();
        _fund(cs, token, avanaLabs, minimum);
    }

    function _fund(
        AvanaFirstLossReserve cs,
        MockDebtAsset token,
        address funder,
        uint256 amount
    ) internal returns (uint256 shares) {
        token.mint(funder, amount);
        vm.startPrank(funder);
        token.approve(address(cs), amount);
        shares = cs.fund(amount);
        vm.stopPrank();
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
