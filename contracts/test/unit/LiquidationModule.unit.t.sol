// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationModule} from "../../src/LiquidationModule.sol";
import {ILPOracle} from "../../src/interfaces/ILPOracle.sol";
import {ILiquidationModule} from "../../src/interfaces/ILiquidationModule.sol";
import {IVaultToken} from "../../src/interfaces/IVaultToken.sol";
import {LiquidationMath} from "../../src/libraries/LiquidationMath.sol";
import {LiquidationModuleTestBase} from "../utils/LiquidationModuleTestBase.sol";
import {LiquidationTestSpoke} from "../utils/mocks/LiquidationTestMocks.sol";

/// @notice LiquidationModule: partial liquidation in kind on the Full range and the Custom range market, the 20% fee
/// share in pool tokens, the least-excess-first unwind order, and every revert.
contract LiquidationModuleUnitTest is LiquidationModuleTestBase {
    // ─── Construction ───

    function test_constructor_bindsRiskModuleAndVault() public view {
        assertEq(module.RISK_MODULE(), address(rm));
        assertEq(module.LP_VAULT(), address(vault));
    }

    function test_constructor_revertsOnZeroRiskModule() public {
        vm.expectRevert(abi.encodeWithSelector(ILiquidationModule.InvalidAddress.selector, address(0)));
        new LiquidationModule(address(0));
    }

    function test_constructor_revertsWhenRiskModuleNamesAnother() public {
        vm.expectRevert(ILiquidationModule.InvalidDeployment.selector);
        new LiquidationModule(address(rm));
    }

    // ─── Full range ───

    /// @notice 1,000 credit, 720 debt; the collateral factor falls to 70% (health factor 0.97). A liquidator repays 100
    /// at a 5% bonus: Aave seizes 105 units, 5 of them bonus; Avana's 20% of it, 1 unit, goes to the fee recipient.
    function test_fullRange_partialInKind() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1000e18);
        (uint256 marketId, address account) = _openUnhealthy(alice, key, 9000, 7000);
        assertEq(marketId, FULL);
        uint256 hfBefore = spoke.healthFactor(account);
        uint256 supplyBefore = vtFull.totalSupply();

        ILiquidationModule.LiquidationResult memory r = _liquidate(FULL, account, 100e18);

        assertEq(r.debtRepaid, 100e18, "repaid");
        assertEq(r.seized, 105e18, "seized");
        assertEq(r.feeUnits, 1e18, "20% of the 5-unit bonus");
        assertEq(vtFull.totalSupply(), supplyBefore - 105e18, "seized units burned");
        assertApproxEqRel(r.creditUnwound, 105e18, 1e6, "credit unwound = seized for a band-wide position");
        assertEq(r.fee0, (r.amount0 + r.fee0) / 105, "fee token0 = 1/105");
        assertEq(token0.balanceOf(liquidator), r.amount0);
        assertEq(token1.balanceOf(liquidator), r.amount1);
        assertEq(token0.balanceOf(feeRecipient), r.fee0);
        assertEq(token1.balanceOf(feeRecipient), r.fee1);
        assertGt(spoke.healthFactor(account), hfBefore, "health improves");
        assertEq(pm.ownerOf(uint256(key)), address(vault), "the NFT stays pledged");
        assertApproxEqRel(vault.getPosition(key).credit, 895e18, 1e6, "the borrower keeps the rest");
        _assertModuleEmpty();
    }

    function test_fullRange_emitsEvents() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1000e18);
        (, address account) = _openUnhealthy(alice, key, 9000, 7000);
        vm.expectEmit(true, true, true, false, address(module));
        emit ILiquidationModule.Liquidated(account, FULL, liquidator, DEBT_RESERVE, 0, 0, 0, 0, 0);
        vm.expectEmit(true, true, true, false, address(module));
        emit ILiquidationModule.FeePaid(account, FULL, feeRecipient, 0, 0, 0);
        _liquidate(FULL, account, 100e18);
    }

    function test_refundsWhatAaveDidNotTake() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1000e18);
        (, address account) = _openUnhealthy(alice, key, 9000, 7000);
        spoke.setClose(5000);
        uint256 before = usdc.balanceOf(liquidator);
        ILiquidationModule.LiquidationResult memory r = _liquidate(FULL, account, 1000e18);
        assertEq(r.debtRepaid, 360e18, "Aave closes half");
        assertEq(before - usdc.balanceOf(liquidator), 360e18, "the rest is refunded");
        _assertModuleEmpty();
    }

    // ─── Custom range ───

    /// @notice Two positions in the Custom range market: one on the whole band (no excess) and a narrow one (excess).
    /// The band-wide one is unwound first and the narrow one is not touched.
    function test_customRange_leastExcessFirst() public {
        bytes32 narrow = _mint(alice, -100, 100, 1000e18);
        bytes32 wide = _mint(alice, BAND_LOWER, BAND_UPPER, 1000e18);
        (uint256 m1,) = _pledge(alice, narrow);
        (uint256 m2, uint128 wideCredit) = _pledge(alice, wide);
        assertEq(m1, CUSTOM);
        assertEq(m2, CUSTOM);
        address account = _account(alice, CUSTOM);
        uint128 narrowCredit = vault.getPosition(narrow).credit;
        _borrow(alice, CUSTOM, (uint256(narrowCredit) + wideCredit) * 7000 / 10_000);
        spoke.setCf(CUSTOM, 6500);

        (ILiquidationModule.UnwindStep[] memory steps, uint256 shortfall) = module.previewUnwind(account, CUSTOM, 50e18);
        assertEq(steps.length, 1);
        assertEq(steps[0].positionKey, wide, "band-wide first");
        assertEq(shortfall, 0);
        // Past the band-wide position the plan moves on to the narrow one: the sort keeps every position, so no
        // position drops out of the plan and none is unwound twice.
        (steps,) = module.previewUnwind(account, CUSTOM, uint256(wideCredit) + 10e18);
        assertEq(steps.length, 2);
        assertEq(steps[0].positionKey, wide, "band-wide first");
        assertEq(steps[1].positionKey, narrow, "then the narrow one");

        _liquidate(CUSTOM, account, 40e18);
        assertEq(vault.getPosition(narrow).credit, narrowCredit, "narrow untouched");
        assertLt(vault.getPosition(wide).credit, wideCredit);
        _assertModuleEmpty();
    }

    /// @notice A narrow position is worth more than its credit, so covering a seized amount from it removes less credit
    /// than the units seized: only the liquidity worth the seized units leaves.
    function test_customRange_narrowPositionUnwindsByValue() public {
        bytes32 narrow = _mint(alice, -100, 100, 1000e18);
        (, uint128 credit) = _pledge(alice, narrow);
        (ILiquidationModule.UnwindStep[] memory steps,) =
            module.previewUnwind(_account(alice, CUSTOM), CUSTOM, uint256(credit) / 10);
        assertEq(steps.length, 1);
        assertLt(steps[0].credit, uint256(credit) / 10, "less credit than units");
        assertEq(steps[0].units, uint256(credit) / 10);
    }

    function test_plan_spillsToTheNextPosition() public {
        bytes32 wide = _mint(alice, BAND_LOWER, BAND_UPPER, 100e18);
        bytes32 narrow = _mint(alice, -100, 100, 1000e18);
        (, uint128 wideCredit) = _pledge(alice, wide);
        _pledge(alice, narrow);
        (ILiquidationModule.UnwindStep[] memory steps,) =
            module.previewUnwind(_account(alice, CUSTOM), CUSTOM, uint256(wideCredit) + 10e18);
        assertEq(steps.length, 2);
        assertEq(steps[0].positionKey, wide);
        assertEq(steps[0].credit, wideCredit, "whole first position");
        assertEq(steps[1].positionKey, narrow);
        assertApproxEqAbs(steps[1].units, 10e18, 1e6, "the rest, less the first position's rounding");
    }

    function test_plan_reportsShortfall() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 10e18);
        (, uint128 credit) = _pledge(alice, key);
        (, uint256 shortfall) = module.previewUnwind(_account(alice, FULL), FULL, uint256(credit) * 2);
        assertApproxEqRel(shortfall, credit, 1e6);
    }

    // ─── Deficit ───

    function test_emptiedAccount_recordsDeficitAndPaysEverything() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1000e18);
        (, address account) = _openUnhealthy(alice, key, 9900, 1000);
        spoke.setBonus(13_000);
        ILiquidationModule.LiquidationResult memory r = _liquidate(FULL, account, 10_000e18);
        assertEq(r.seized, 1000e18, "all collateral");
        assertGt(spoke.deficit(DEBT_RESERVE), 0, "the rest is a deficit");
        assertEq(vault.getPosition(key).credit, 0);
        _assertModuleEmpty();
    }

    // ─── Fee ───

    function test_noFeeWithoutRecipient() public {
        rm.setFee(FEE_SHARE_BPS, address(0));
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1000e18);
        (, address account) = _openUnhealthy(alice, key, 9000, 7000);
        ILiquidationModule.LiquidationResult memory r = _liquidate(FULL, account, 100e18);
        assertEq(r.feeUnits, 0);
        assertEq(r.fee0 + r.fee1, 0);
    }

    /// @notice The ARFC example: 4,998 vault tokens seized at a 2% bonus hold 98 of bonus; Avana's 20% is 19.6.
    function test_feeUnits_arfcExample() public pure {
        assertEq(LiquidationMath.feeUnits(4998e18, 10_200, 2000), 19.6e18);
        assertEq(LiquidationMath.feeUnits(4998e18, 10_000, 2000), 0, "no bonus, no fee");
        // At a 100% bonus half the seized units are bonus: 1,000 seized hold 500 of bonus, Avana's 20% is 100.
        assertEq(LiquidationMath.feeUnits(1000e18, 20_000, 2000), 100e18, "100% bonus");
    }

    /// @notice A WETH/USDC position's worth at the oracle prices: 1 WETH (18 decimals) at $3,000 and 3,000 USDC
    /// (6 decimals) at $1 are worth $6,000 in 18 decimals, whichever side each token is on. A wrong worth moves the
    /// least-excess-first order and the credit unwound per seized unit.
    function test_value_wethUsdcAtOraclePrices() public pure {
        assertEq(LiquidationMath.value(1e18, 3000e6, 3000e8, 1e8, 18, 6), 6000e18, "WETH as token0");
        assertEq(LiquidationMath.value(3000e6, 1e18, 1e8, 3000e8, 6, 18), 6000e18, "WETH as token1");
        assertEq(LiquidationMath.feeUnits(4998e18, 10_200, 0), 0, "no share, no fee");
    }

    // ─── Reverts ───

    function test_revertsOnHealthyAccount() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1000e18);
        _pledge(alice, key);
        _borrow(alice, FULL, 100e18);
        address account = _account(alice, FULL);
        vm.prank(liquidator);
        vm.expectRevert(LiquidationTestSpoke.Healthy.selector);
        module.liquidate(_p(FULL, account, 10e18, 0, liquidator));
    }

    function test_directLiquidationCallReverts() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1000e18);
        (, address account) = _openUnhealthy(alice, key, 9000, 7000);
        vm.startPrank(liquidator);
        usdc.approve(address(spoke), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, address(hub), liquidator));
        spoke.liquidationCall(FULL, DEBT_RESERVE, account, 100e18, false);
        vm.stopPrank();
    }

    /// @notice Bug hunted: a plan for an account with no pledged position that reports cover it does not have. A
    /// liquidator's preview must show no step and the whole repay as shortfall, so no one is told a dead account pays.
    function test_plan_accountWithoutPositionsShowsTheWholeRepayAsShortfall() public view {
        (ILiquidationModule.UnwindStep[] memory steps, uint256 shortfall) =
            module.previewUnwind(address(0xBEEF), CUSTOM, 10e18);
        assertEq(steps.length, 0);
        assertEq(shortfall, 10e18);
    }

    /// @notice Bug hunted: the liquidator's token0 minimum ignored, so a sandwich before the unwind pays under it.
    function test_revertsBelowMinimum() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1000e18);
        (, address account) = _openUnhealthy(alice, key, 9000, 7000);
        vm.prank(liquidator);
        vm.expectPartialRevert(ILiquidationModule.BelowMinimum.selector);
        module.liquidate(_p(FULL, account, 100e18, 1000e18, liquidator));
    }

    /// @notice Bug hunted: the liquidator's token1 minimum ignored. A liquidation whose token1 payout falls under the
    /// liquidator's bound (a price moved by a sandwich before the unwind) must revert like the token0 bound does.
    function test_revertsBelowTheToken1Minimum() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1000e18);
        (, address account) = _openUnhealthy(alice, key, 9000, 7000);
        ILiquidationModule.LiquidationParams memory p = _p(FULL, account, 100e18, 0, liquidator);
        p.minAmount1 = 1000e18;
        vm.prank(liquidator);
        vm.expectPartialRevert(ILiquidationModule.BelowMinimum.selector);
        module.liquidate(p);
        p.minAmount1 = 0;
        vm.prank(liquidator);
        module.liquidate(p);
        _assertModuleEmpty();
    }

    /// @notice Bug hunted: a plan step that unwinds zero credit. Asking a narrow position (worth more units than its
    /// credit) for one unit rounds its credit to 0; the plan must skip it rather than call `unwind(key, 0)`, which the
    /// LPVault refuses, so that one dust step would revert the whole liquidation.
    function test_plan_skipsAStepThatRoundsToZeroCredit() public {
        bytes32 narrow = _mint(alice, -100, 100, 1000e18);
        _pledge(alice, narrow);
        (ILiquidationModule.UnwindStep[] memory steps, uint256 shortfall) =
            module.previewUnwind(_account(alice, CUSTOM), CUSTOM, 1);
        assertEq(steps.length, 0, "no zero-credit step");
        assertEq(shortfall, 0, "the dust unit is forgone, not reported as a shortfall");
    }

    /// @notice Bug hunted: an emptied position planned again. After a liquidation takes all of an account's credit,
    /// its record stays in the LPVault with credit 0; a later plan must leave it out (its capacity would divide by
    /// zero credit) and report the units as shortfall.
    function test_plan_leavesOutAPositionWithNoCredit() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1000e18);
        (, address account) = _openUnhealthy(alice, key, 9900, 1000);
        spoke.setBonus(13_000);
        _liquidate(FULL, account, 10_000e18);
        assertEq(vault.getPosition(key).credit, 0);
        (ILiquidationModule.UnwindStep[] memory steps, uint256 shortfall) = module.previewUnwind(account, FULL, 1e18);
        assertEq(steps.length, 0);
        assertEq(shortfall, 1e18);
    }

    /// @notice Bug hunted: a market whose vault-token unit is worth less than the smallest value step makes every plan
    /// divide by zero, so no account of that market can be liquidated. A unit valued at 0 is taken as worth 1, which
    /// only raises each position's capacity, and the plan still covers the units.
    function test_plan_survivesAUnitValuedAtZero() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 10e18);
        (, uint128 credit) = _pledge(alice, key);
        vm.mockCall(
            rm.getMarket(FULL).lpOracle, abi.encodeWithSelector(ILPOracle.getUnitAmounts.selector), abi.encode(0, 0)
        );
        (ILiquidationModule.UnwindStep[] memory steps, uint256 shortfall) =
            module.previewUnwind(_account(alice, FULL), FULL, uint256(credit) / 2);
        assertEq(steps.length, 1);
        assertEq(steps[0].positionKey, key);
        assertEq(steps[0].units, uint256(credit) / 2);
        assertGt(steps[0].credit, 0);
        assertEq(shortfall, 0);
    }

    function test_revertsOnBadArguments() public {
        vm.startPrank(liquidator);
        vm.expectRevert(ILiquidationModule.InvalidAmount.selector);
        module.liquidate(_p(FULL, alice, 0, 0, liquidator));
        vm.expectRevert(abi.encodeWithSelector(ILiquidationModule.InvalidAddress.selector, address(0)));
        module.liquidate(_p(FULL, alice, 1, 0, address(0)));
        vm.expectRevert(abi.encodeWithSelector(ILiquidationModule.InvalidAddress.selector, address(module)));
        module.liquidate(_p(FULL, alice, 1, 0, address(module)));
        vm.expectRevert(abi.encodeWithSelector(ILiquidationModule.InvalidAddress.selector, address(0)));
        module.liquidate(_p(FULL, address(0), 1, 0, liquidator));
        vm.expectRevert(abi.encodeWithSelector(ILiquidationModule.MarketNotActive.selector, 99));
        module.liquidate(_p(99, alice, 1, 0, liquidator));
        vm.stopPrank();
    }

    function test_revertsWhenNothingSeized() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1000e18);
        (, address account) = _openUnhealthy(alice, key, 9000, 7000);
        // A repayment too small to seize one unit at a price of 2 debt units per collateral unit.
        spoke.setPrice(FULL, 2);
        spoke.setCf(FULL, 3000);
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationModule.NothingSeized.selector, account));
        module.liquidate(_p(FULL, account, 1, 0, liquidator));
    }

    // ─── Helpers ───

    function _p(
        uint256 marketId,
        address account,
        uint256 debtToCover,
        uint256 min0,
        address receiver
    ) internal pure returns (ILiquidationModule.LiquidationParams memory) {
        return ILiquidationModule.LiquidationParams(marketId, DEBT_RESERVE, account, debtToCover, min0, 0, receiver);
    }

    function _assertModuleEmpty() internal view {
        assertEq(token0.balanceOf(address(module)), 0, "no token0 left");
        assertEq(token1.balanceOf(address(module)), 0, "no token1 left");
        assertEq(usdc.balanceOf(address(module)), 0, "no debt token left");
        assertEq(vtFull.balanceOf(address(module)), 0, "no full vault tokens left");
        assertEq(vtCustom.balanceOf(address(module)), 0, "no custom vault tokens left");
        // An allowance left on the Spoke would let it pull the debt token of the next liquidator, who pays this
        // module first, for a liquidation that liquidator did not ask for.
        assertEq(usdc.allowance(address(module), address(spoke)), 0, "no allowance left on the Spoke");
    }
}
