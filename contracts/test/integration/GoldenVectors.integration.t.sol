// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {Deployments} from "../utils/Deployments.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SharesMath} from "aave-v4/hub/libraries/SharesMath.sol";

/// @dev Hub `SpokeConfig` of aave-v4 a3ef63e.
struct GvHubSpokeConfig {
    uint40 addCap;
    uint40 drawCap;
    uint24 riskPremiumThreshold;
    bool active;
    bool halted;
}

/// @dev Spoke `ReserveConfig` of aave-v4 a3ef63e.
struct GvReserveConfig {
    uint24 collateralRisk;
    bool paused;
    bool frozen;
    bool borrowable;
    bool receiveSharesEnabled;
}

/// @dev Spoke `DynamicReserveConfig` of aave-v4 a3ef63e.
struct GvDynamicReserveConfig {
    uint16 collateralFactor;
    uint32 maxLiquidationBonus;
    uint16 liquidationFee;
}

/// @dev Spoke `LiquidationConfig` of aave-v4 a3ef63e.
struct GvLiquidationConfig {
    uint128 targetHealthFactor;
    uint64 healthFactorForMaxBonus;
    uint16 liquidationBonusFactor;
}

/// @dev `AssetInterestRateStrategy.InterestRateData` of aave-v4 a3ef63e.
struct GvInterestRateData {
    uint16 optimalUsageRatio;
    uint32 baseDrawnRate;
    uint32 rateGrowthBeforeOptimal;
    uint32 rateGrowthAfterOptimal;
}

interface IGvHubConfigurator {
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
        GvHubSpokeConfig calldata config
    ) external;
}

interface IGvSpokeConfigurator {
    function addReserve(
        address spoke,
        address hub,
        uint256 assetId,
        address priceSource,
        GvReserveConfig calldata config,
        GvDynamicReserveConfig calldata dynamicConfig
    ) external returns (uint256);
    function updateLiquidationConfig(
        address spoke,
        GvLiquidationConfig calldata config
    ) external;
}

/// @notice Mintable token with chosen decimals.
contract GvToken is ERC20 {
    uint8 private immutable DECIMALS;

    constructor(
        string memory symbol,
        uint8 decimals_
    ) ERC20(symbol, symbol) {
        DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

/// @notice 8-decimal price source the AaveOracle reads with `latestAnswer`.
contract GvPrice {
    int256 public latestAnswer;

    constructor(
        int256 answer
    ) {
        latestAnswer = answer;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function set(
        int256 answer
    ) external {
        latestAnswer = answer;
    }
}

/// @title GoldenVectorsIntegrationTest
/// @notice Worked examples of the specification recomputed on the pinned Aave V4 release deployed by the fixture: the
/// standard CDP Spoke Avana deploys (`SpokeInstance` with the real `LiquidationLogic`) and the Stable LP Hub. Each
/// expected integer is the value the exact-integer model of the Aave V4 arithmetic
/// (`spec/05-verification/z3/aave-risk/_v4ref.py`) gives for the example; the comments carry the rounded figure the
/// example states. Collateral is a plain 18-decimal token at $10 (6 decimals at $2 for `LIQ-068`), debt an 18-decimal
/// asset at the fixed $1 GHO price; no time passes, so the drawn index stays 1 RAY, and every collateral reserve has
/// collateral risk 0, so no premium accrues.
contract GoldenVectorsIntegrationTest is Deployments {
    GvToken internal debt;
    GvPrice internal debtPrice;
    uint256 internal debtReserveId;
    bytes internal irData;

    address internal liquidator = makeAddr("liquidator");

    function setUp() public {
        _deployAaveV4();
        irData = abi.encode(GvInterestRateData(9000, 0, 400, 6000));
        debt = new GvToken("GHO", 18);
        debtPrice = new GvPrice(1e8);
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        uint40 maxCap = hubView.MAX_ALLOWED_SPOKE_CAP();
        uint24 maxRp = hubView.MAX_RISK_PREMIUM_THRESHOLD();
        IGvHubConfigurator hubCfg = IGvHubConfigurator(aave.hubConfigurator);
        IGvSpokeConfigurator spokeCfg = IGvSpokeConfigurator(aave.spokeConfigurator);

        vm.startPrank(aaveDao);
        uint256 debtAssetId =
            hubCfg.addAssetWithDecimals(aave.hub, address(debt), 18, aave.treasurySpoke, 0, aave.irStrategy, irData);
        hubCfg.addSpoke(aave.hub, aave.lendSpoke, debtAssetId, GvHubSpokeConfig(maxCap, 0, maxRp, true, false));
        hubCfg.addSpoke(aave.hub, aave.cdpSpoke, debtAssetId, GvHubSpokeConfig(0, maxCap, maxRp, true, false));
        uint256 lendReserveId = spokeCfg.addReserve(
            aave.lendSpoke,
            aave.hub,
            debtAssetId,
            address(debtPrice),
            GvReserveConfig(0, false, false, true, false),
            GvDynamicReserveConfig(0, 10_000, 0)
        );
        debtReserveId = spokeCfg.addReserve(
            aave.cdpSpoke,
            aave.hub,
            debtAssetId,
            address(debtPrice),
            GvReserveConfig(0, false, false, true, false),
            GvDynamicReserveConfig(0, 10_000, 0)
        );
        vm.stopPrank();

        debt.mint(daoTreasury, 10_000_000e18);
        vm.startPrank(daoTreasury);
        debt.approve(aave.lendSpoke, 10_000_000e18);
        IAaveV4Spoke(aave.lendSpoke).supply(lendReserveId, 10_000_000e18, daoTreasury);
        vm.stopPrank();
    }

    // ─── TEST-076: ARFC examples on the real bonus curve and dust rule ───

    // TEST-076 verifies: SPEC-CF-001, SPEC-HUB-008
    // Sources: 5.1 TEST-076, SYM-61, SYM-63, SYM-67 (a $100,000 position at CF 35 %, 25,000 GHO borrowed)
    function test_TEST_076_capacityAndHealthFactor() public {
        (GvToken coll, GvPrice price, uint256 collReserve) = _addCollateral(18, 3500, 10_500, 10e8);
        _supply(alice, coll, collReserve, 10_000e18); // $100,000

        // Capacity: 35,000 GHO borrows exactly to health factor 1; one wei more is refused.
        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("HealthFactorBelowThreshold()")));
        IAaveV4Spoke(aave.cdpSpoke).borrow(debtReserveId, 35_000e18 + 1, alice);
        vm.prank(alice);
        IAaveV4Spoke(aave.cdpSpoke).borrow(debtReserveId, 35_000e18, alice);
        assertEq(_hf(alice), 1e18, "capacity 35,000 GHO: hf 1");

        // 25,000 GHO borrowed: hf 1.40; at $70,000 of collateral: hf 0.98.
        vm.startPrank(alice);
        debt.approve(aave.cdpSpoke, 10_000e18);
        IAaveV4Spoke(aave.cdpSpoke).repay(debtReserveId, 10_000e18, alice);
        vm.stopPrank();
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserTotalDebt(debtReserveId, alice), 25_000e18, "debt");
        assertEq(_hf(alice), 1.4e18, "hf 1.40");
        price.set(7e8);
        assertEq(_hf(alice), 0.98e18, "hf 0.98 at $70,000");
    }

    // TEST-076 verifies: SPEC-HUB-005, SPEC-HUB-008
    // Sources: 5.1 TEST-076, SYM-67 to SYM-70 (hf 0.98, flat 5 % bonus, target 1.05: repays about 2,564 GHO, removes
    // about $2,692, leaves 22,436 GHO and about $67,300)
    function test_TEST_076_partialLiquidationToTarget() public {
        (GvToken coll, GvPrice price, uint256 collReserve) = _addCollateral(18, 3500, 10_500, 20e8);
        _config(1.05e18, 0.99e18, 0);
        _supply(alice, coll, collReserve, 10_000e18);
        _borrow(alice, 25_000e18);
        price.set(7e8);
        assertEq(_hf(alice), 0.98e18, "hf 0.98");
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getLiquidationBonus(collReserve, alice, 0.98e18), 10_500, "bonus 5 %");

        (uint256 paid, uint256 seized) = _liquidate(coll, collReserve, alice, 25_000e18);
        assertEq(paid, 2_564_102_564_102_564_102_565, "repays 2,564.10 GHO");
        assertEq(seized, 384_615_384_615_384_615_384, "removes 384.62 tokens ($2,692.31)");
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserTotalDebt(debtReserveId, alice), 22_435_897_435_897_435_897_435);
        assertEq(_hf(alice), 1.05e18, "target 1.05 reached");
    }

    // TEST-076 verifies: SPEC-HUB-005
    // Sources: 5.1 TEST-076, MATH-AR-14 ($50,000 of LP, 15,918 GHO, CF 31.2 %, target 1.10; bonus 5.00 %, repaid
    // 2,472.55 GHO, seized $2,596.18, debt left 13,445.45)
    function test_TEST_076_flatMaxBonusRow() public {
        _arfcRow(0, 0.99e18, 10_500, 2_472_553_081_305_023_318_693, 259_618_073_537_027_448_462);
    }

    // TEST-076 verifies: SPEC-HUB-005
    // Sources: 5.1 TEST-076, MATH-AR-14 (SPEC-HUB-005 example: LBF 40 %, hfForMaxBonus 0.90; bonus 2.59 %, repaid
    // 2,448.72 GHO, seized $2,512.14)
    function test_TEST_076_specExampleCurveRow() public {
        _arfcRow(4000, 0.9e18, 10_259, 2_448_715_200_241_255_775_417, 251_213_692_392_750_430_000);
    }

    // TEST-076 verifies: SPEC-HUB-005
    // Sources: 5.1 TEST-076, MATH-AR-14 (LBF 20 %, hfForMaxBonus 0.70; bonus 1.26 %, repaid 2,435.76 GHO, seized
    // $2,466.45)
    function test_TEST_076_lowFactorCurveRow() public {
        _arfcRow(2000, 0.7e18, 10_126, 2_435_755_637_770_563_005_897, 246_644_615_880_647_209_977);
    }

    // TEST-076 verifies: SPEC-HUB-005
    // Sources: 5.1 TEST-076, MATH-AR-14 (LBF 0 %, hfForMaxBonus 0.90; bonus 0.99 %, repaid 2,433.14 GHO, seized
    // $2,457.23)
    function test_TEST_076_zeroFactorCurveRow() public {
        _arfcRow(0, 0.9e18, 10_099, 2_433_141_481_482_236_476_379, 245_722_958_214_891_061_749);
    }

    // TEST-076 verifies: SPEC-HUB-008, Q-169
    // Sources: 5.1 TEST-076, MATH-AR-15a (hf 0.98, CF 35 %, maxLB 5 %, LBF 20 %, hfMax 0.70, target 1.05: a
    // 1,000 GHO account is liquidated in full, $1,012.60 seized)
    function test_TEST_076_dustRuleTakesSmallAccountInFull() public {
        _dustRow(280e18, 1000e18, 1000e18, 101_260_000_000_000_000_000);
    }

    // TEST-076 verifies: SPEC-HUB-008, Q-169
    // Sources: 5.1 TEST-076, MATH-AR-15a (1,111 GHO: liquidated in full, $1,125.00 seized)
    function test_TEST_076_dustRuleAtTheEdge() public {
        _dustRow(311.08e18, 1111e18, 1111e18, 112_499_860_000_000_000_000);
    }

    // TEST-076 verifies: SPEC-HUB-008, Q-169
    // Sources: 5.1 TEST-076, MATH-AR-15a (1,112 GHO: partial, repaid 111.91, debt left 1,000.09)
    function test_TEST_076_justAboveTheDustEdgeIsPartial() public {
        _dustRow(311.36e18, 1112e18, 111_905_001_509_509_912_449, 11_331_500_452_852_973_734);
        assertEq(_hf(alice), 1.05e18, "target reached");
    }

    // TEST-076 verifies: SPEC-HUB-008, Q-169
    // Sources: 5.1 TEST-076, MATH-AR-15a (1,500 GHO: partial, repaid 150.95, debt left 1,349.05)
    function test_TEST_076_largerAccountIsPartial() public {
        _dustRow(420e18, 1500e18, 150_950_991_244_842_507_800, 15_285_297_373_452_752_339);
        assertEq(_hf(alice), 1.05e18, "target reached");
    }

    // TEST-076 verifies: SPEC-HUB-008, Q-169
    // Sources: 5.1 TEST-076, MATH-AR-15a (cover 200 GHO on the 1,000 GHO account reverts MustNotLeaveDust)
    function test_TEST_076_partialCoverThatLeavesDustReverts() public {
        (GvToken coll, GvPrice price, uint256 collReserve) = _addCollateral(18, 3500, 10_500, 20e8);
        _config(1.05e18, 0.7e18, 2000);
        _supply(alice, coll, collReserve, 280e18);
        _borrow(alice, 1000e18);
        price.set(10e8);
        debt.mint(liquidator, 200e18);
        vm.startPrank(liquidator);
        debt.approve(aave.cdpSpoke, 200e18);
        vm.expectRevert(bytes4(keccak256("MustNotLeaveDust()")));
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(collReserve, debtReserveId, alice, 200e18, false);
        vm.stopPrank();
    }

    // TEST-076 verifies: SPEC-HUB-008, Q-169
    // Sources: 5.1 TEST-076, MATH-AR-15b ($600 + $2,700 on one Spoke, 1,200 GHO, hf 0.9625; seizing the $600 reserve
    // in full repays 591.13 GHO and leaves 608.87 GHO at hf 1.5521)
    function test_TEST_076_collateralDustLeavesDebtBelowTheDustLine() public {
        (GvToken collA, GvPrice priceA, uint256 reserveA) = _addCollateral(18, 3500, 10_500, 20e8);
        (GvToken collB, GvPrice priceB, uint256 reserveB) = _addCollateral(18, 3500, 10_500, 20e8);
        _config(1.05e18, 0.7e18, 2000);
        _supply(alice, collA, reserveA, 60e18);
        _supply(alice, collB, reserveB, 270e18);
        _borrow(alice, 1200e18);
        priceA.set(10e8);
        priceB.set(10e8);
        assertEq(_hf(alice), 0.9625e18, "hf 0.9625");

        (uint256 paid, uint256 seized) = _liquidate(collA, reserveA, alice, 1200e18);
        assertEq(seized, 60e18, "the $600 reserve in full");
        assertEq(paid, 591_133_004_926_108_374_385, "repaid 591.13 GHO");
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserTotalDebt(debtReserveId, alice), 608_866_995_073_891_625_615);
        assertEq(_hf(alice), 1_552_063_106_796_116_504, "hf 1.5521");
    }

    // ─── TEST-282: worked-example arithmetic ───

    // TEST-282 verifies: DEF-006, SPEC-FLR-001
    // Sources: 5.1 TEST-282, 3.9 DEF-006, FINDING on DEF-006 (virtual offset)
    function test_TEST_282_def006SharesUseTheVirtualOffset() public pure {
        uint256 amount = 475.3e18;
        uint256 addedAssets = 2_050_000e18;
        uint256 addedShares = 2_000_000e18;
        // The Hub's rounding (`AssetLogic.toAddedSharesUp` -> `SharesMath.toSharesUp`).
        uint256 shares = SharesMath.toSharesUp(amount, addedAssets, addedShares);
        assertEq(shares, 463_707_317_073_170_731_713, "ceil(475.3e18 x (2,000,000e18 + 1e6) / (2,050,000e18 + 1e6))");
        assertEq(SharesMath.VIRTUAL_ASSETS, 1e6, "virtual assets");
        assertEq(SharesMath.VIRTUAL_SHARES, 1e6, "virtual shares");
        // Without the offset the same division gives ...708, which the example must not state.
        uint256 noOffset = (amount * addedShares + addedAssets - 1) / addedAssets;
        assertEq(noOffset, 463_707_317_073_170_731_708, "value without the offset");
        assertTrue(shares != noOffset, "the offset changes the result");
    }

    // TEST-282 verifies: LIQ-068
    // Sources: 5.1 TEST-282, 3.5 LIQ-068 (282,464 x 0.2812 / 79,452.85 = 0.999698..., about 0.9997, floors to 0.9996)
    function test_TEST_282_liq068HealthFactor() public {
        uint256 exact = 282_464e18 * 2812 * WAD / (10_000 * 79_452.85e18);
        assertEq(exact, 999_698_271_364_715_047, "0.999698...");
        assertEq(exact / 1e14, 9996, "floors to 0.9996 at 4 decimals");
        assertEq((exact + 0.5e14) / 1e14, 9997, "rounds to 0.9997");

        // The same account on the real Spoke: 141,232 vault-token units of 6 decimals at $2, CF 2,812, 79,452.85 GHO.
        (GvToken coll, GvPrice price, uint256 collReserve) = _addCollateral(6, 2812, 10_500, 4e8);
        _supply(alice, coll, collReserve, 141_232e6);
        _borrow(alice, 79_452.85e18);
        price.set(2e8);
        assertEq(_hf(alice), exact, "Spoke health factor equals the example's arithmetic");
    }

    // ─── Helpers ───

    function _arfcRow(
        uint16 lbf,
        uint64 hfForMaxBonus,
        uint256 bonus,
        uint256 paidExpected,
        uint256 seizedExpected
    ) internal {
        (GvToken coll, GvPrice price, uint256 collReserve) = _addCollateral(18, 3120, 10_500, 20e8);
        _config(1.1e18, hfForMaxBonus, lbf);
        _supply(alice, coll, collReserve, 5000e18); // $50,000 at $10
        _borrow(alice, 15_918e18);
        price.set(10e8);
        assertEq(_hf(alice), 980_022_615_906_520_919, "hf 0.98");
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getLiquidationBonus(collReserve, alice, _hf(alice)), bonus, "bonus");

        (uint256 paid, uint256 seized) = _liquidate(coll, collReserve, alice, 15_918e18);
        assertEq(paid, paidExpected, "repaid");
        assertEq(seized, seizedExpected, "seized");
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserTotalDebt(debtReserveId, alice), 15_918e18 - paidExpected);
        assertEq(_hf(alice), 1.1e18, "target 1.10 reached");
    }

    function _dustRow(
        uint256 collAmount,
        uint256 debtAmount,
        uint256 paidExpected,
        uint256 seizedExpected
    ) internal {
        (GvToken coll, GvPrice price, uint256 collReserve) = _addCollateral(18, 3500, 10_500, 20e8);
        _config(1.05e18, 0.7e18, 2000);
        _supply(alice, coll, collReserve, collAmount);
        _borrow(alice, debtAmount);
        price.set(10e8);
        assertEq(_hf(alice), 0.98e18, "hf 0.98");
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getLiquidationBonus(collReserve, alice, 0.98e18), 10_126, "bonus");

        (uint256 paid, uint256 seized) = _liquidate(coll, collReserve, alice, debtAmount);
        assertEq(paid, paidExpected, "repaid");
        assertEq(seized, seizedExpected, "seized");
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserTotalDebt(debtReserveId, alice), debtAmount - paidExpected);
    }

    function _addCollateral(
        uint8 decimals,
        uint16 collateralFactor,
        uint32 maxLiquidationBonus,
        int256 answer
    ) internal returns (GvToken coll, GvPrice price, uint256 reserveId) {
        coll = new GvToken("COLL", decimals);
        price = new GvPrice(answer);
        uint256 assetId = _addCollateralAsset(address(coll), decimals);
        vm.prank(aaveDao);
        reserveId = IGvSpokeConfigurator(aave.spokeConfigurator)
            .addReserve(
                aave.cdpSpoke,
                aave.hub,
                assetId,
                address(price),
                GvReserveConfig(0, false, false, false, false),
                GvDynamicReserveConfig(collateralFactor, maxLiquidationBonus, 0)
            );
    }

    function _addCollateralAsset(
        address coll,
        uint8 decimals
    ) internal returns (uint256 assetId) {
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        GvHubSpokeConfig memory cfg =
            GvHubSpokeConfig(hubView.MAX_ALLOWED_SPOKE_CAP(), 0, hubView.MAX_RISK_PREMIUM_THRESHOLD(), true, false);
        vm.startPrank(aaveDao);
        assetId = IGvHubConfigurator(aave.hubConfigurator)
            .addAssetWithDecimals(aave.hub, coll, decimals, aave.treasurySpoke, 0, aave.irStrategy, irData);
        IGvHubConfigurator(aave.hubConfigurator).addSpoke(aave.hub, aave.cdpSpoke, assetId, cfg);
        vm.stopPrank();
    }

    function _config(
        uint128 targetHealthFactor,
        uint64 healthFactorForMaxBonus,
        uint16 liquidationBonusFactor
    ) internal {
        vm.prank(aaveDao);
        IGvSpokeConfigurator(aave.spokeConfigurator)
            .updateLiquidationConfig(
                aave.cdpSpoke, GvLiquidationConfig(targetHealthFactor, healthFactorForMaxBonus, liquidationBonusFactor)
            );
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
        vm.prank(user);
        IAaveV4Spoke(aave.cdpSpoke).borrow(debtReserveId, amount, user);
    }

    function _liquidate(
        GvToken coll,
        uint256 collReserve,
        address user,
        uint256 cover
    ) internal returns (uint256 paid, uint256 seized) {
        debt.mint(liquidator, cover);
        uint256 debtBefore = debt.balanceOf(liquidator);
        uint256 sharesBefore = IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(collReserve, user);
        vm.startPrank(liquidator);
        debt.approve(aave.cdpSpoke, cover);
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(collReserve, debtReserveId, user, cover, false);
        vm.stopPrank();
        paid = debtBefore - debt.balanceOf(liquidator);
        seized = coll.balanceOf(liquidator);
        assertEq(
            sharesBefore - IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(collReserve, user),
            seized,
            "shares removed equal tokens received (added assets equal shares)"
        );
    }

    function _hf(
        address user
    ) internal view returns (uint256) {
        return IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(user).healthFactor;
    }
}
