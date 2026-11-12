// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SettlementMath} from "../../../src/liquidation/lp-vault-swap/SettlementMath.sol";

/// @title SettlementMathHarness
/// @notice External wrappers of the internal `SettlementMath` functions, so unit, fuzz and differential suites can
/// call them across a message call (`vm.expectRevert` needs one) and read their reverts.
contract SettlementMathHarness {
    function netBonus(
        uint256 bonus,
        uint256 liquidationFee
    ) external pure returns (uint256) {
        return SettlementMath.netBonus(bonus, liquidationFee);
    }

    function effectiveSlippage(
        uint256 bNet,
        uint256 allowanceBps
    ) external pure returns (uint256) {
        return SettlementMath.effectiveSlippage(bNet, allowanceBps);
    }

    function legSlippage(
        uint256 slippage,
        uint256 maxShortfall,
        uint256 value,
        uint256 maxShortfallBps
    ) external pure returns (uint256) {
        return SettlementMath.legSlippage(slippage, maxShortfall, value, maxShortfallBps);
    }

    function pendingSlippage(
        uint256 allowanceBps
    ) external pure returns (uint256) {
        return SettlementMath.pendingSlippage(allowanceBps);
    }

    function seizedValue(
        uint256 units,
        uint256 collateralPrice,
        uint8 vaultDecimals,
        uint8 debtDecimals,
        uint256 debtPrice
    ) external pure returns (uint256) {
        return SettlementMath.seizedValue(units, collateralPrice, vaultDecimals, debtDecimals, debtPrice);
    }

    function legValue(
        uint256 amount,
        uint256 price,
        uint8 tokenDecimals,
        uint8 debtDecimals,
        uint256 debtPrice
    ) external pure returns (uint256) {
        return SettlementMath.legValue(amount, price, tokenDecimals, debtDecimals, debtPrice);
    }

    function pendingLegValue(
        uint256 amount,
        uint256 price,
        uint8 tokenDecimals,
        uint8 pendingDecimals,
        uint256 pendingPrice
    ) external pure returns (uint256) {
        return SettlementMath.pendingLegValue(amount, price, tokenDecimals, pendingDecimals, pendingPrice);
    }

    function unitValue(
        uint256 price,
        uint8 tokenDecimals,
        uint8 debtDecimals,
        uint256 debtPrice
    ) external pure returns (uint256) {
        return SettlementMath.unitValue(price, tokenDecimals, debtDecimals, debtPrice);
    }

    function recoveryFloor(
        uint256 value,
        uint256 slippage,
        uint256 units,
        uint256 allowance
    ) external pure returns (uint256) {
        return SettlementMath.recoveryFloor(value, slippage, units, allowance);
    }

    function isDustLeg(
        uint256 legValue_,
        uint256 legUnit
    ) external pure returns (bool) {
        return SettlementMath.isDustLeg(legValue_, legUnit);
    }

    function legMinOut(
        uint256 legValue_,
        uint256 sLeg,
        uint256 legUnit,
        uint256 allowance,
        uint256 swappedLegs
    ) external pure returns (uint256) {
        return SettlementMath.legMinOut(legValue_, sLeg, legUnit, allowance, swappedLegs);
    }

    function recoveryWithFloor(
        uint256 minRec,
        uint256 recovered
    ) external pure returns (uint256) {
        return SettlementMath.recoveryWithFloor(minRec, recovered);
    }

    function roundingGap(
        uint256 debtRepaid,
        uint256 avanaFee,
        uint256 borrowerSurplus,
        uint256 callerFunds,
        uint256 recovered
    ) external pure returns (uint256) {
        return SettlementMath.roundingGap(debtRepaid, avanaFee, borrowerSurplus, callerFunds, recovered);
    }

    function shortfallTopUp(
        uint256 minRec,
        uint256 recovered,
        uint256 gap,
        uint256 maxShortfall
    ) external pure returns (uint256) {
        return SettlementMath.shortfallTopUp(minRec, recovered, gap, maxShortfall);
    }

    function payouts(
        uint256 value,
        uint256 debtRepaid,
        uint256 recoveredWithTopUp,
        uint256 feeShareBps
    ) external pure returns (SettlementMath.Payouts memory) {
        return SettlementMath.payouts(value, debtRepaid, recoveredWithTopUp, feeShareBps);
    }

    function keeperPayout(
        uint256 callerFunds,
        uint256 recoveredWithTopUp,
        uint256 debtRepaid,
        uint256 avanaFee,
        uint256 borrowerSurplus
    ) external pure returns (uint256) {
        return SettlementMath.keeperPayout(callerFunds, recoveredWithTopUp, debtRepaid, avanaFee, borrowerSurplus);
    }

    function flashPremiumWithinCap(
        uint256 premium,
        uint256 amount,
        uint256 maxFlashFeeBps
    ) external pure returns (bool) {
        return SettlementMath.flashPremiumWithinCap(premium, amount, maxFlashFeeBps);
    }

    function deleverageCap(
        uint256 value,
        uint256 slippage,
        uint256 units,
        uint256 allowance,
        uint256 maxFlashFeeBps
    ) external pure returns (uint256) {
        return SettlementMath.deleverageCap(value, slippage, units, allowance, maxFlashFeeBps);
    }

    function deleverageRepayment(
        uint256 debt,
        uint256 cap,
        uint256 minDebtRepaid
    ) external pure returns (uint256) {
        return SettlementMath.deleverageRepayment(debt, cap, minDebtRepaid);
    }

    function deleverageAssetOut(
        uint256 recovered,
        uint256 repaid,
        uint256 premium
    ) external pure returns (uint256) {
        return SettlementMath.deleverageAssetOut(recovered, repaid, premium);
    }
}
