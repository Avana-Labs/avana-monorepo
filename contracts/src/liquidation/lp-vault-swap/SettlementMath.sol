// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "./ILPVaultSwapErrors.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// A token with an invalid price or decimals must stop the settlement inside the callers' leg loops.
// forge-lint: disable-start(require-revert-in-loop)
/// @title SettlementMath
/// @notice Settlement arithmetic of LPVaultSwap, in base units of the repaid debt asset: values, floors, leg minimums,
/// the payout waterfall and repay-with-collateral sizing.
/// @dev Each rounding goes against the caller, and up where it raises a floor protecting the First-Loss Reserve.
library SettlementMath {
    uint256 internal constant BPS = 10_000;

    /// @notice Largest slippage a leg may run at when the caller's shortfall top-up relaxes it.
    uint256 internal constant MAX_LEG_SLIPPAGE_BPS = 9999;

    uint256 internal constant PENDING_SLIPPAGE_CAP_BPS = 30;

    uint8 internal constant MAX_DECIMALS = 36;

    /// @notice The split of the realized surplus.
    struct Payouts {
        uint256 surplus;
        uint256 oracleGain;
        uint256 avanaFee;
        uint256 keeperReward;
        uint256 borrowerSurplus;
    }

    /// @notice Net bonus `10⁴ + ⌊(b − 10⁴) × (10⁴ − lf) / 10⁴⌋` bps; `10⁴` when `b ≤ 10⁴` or `lf ≥ 10⁴`.
    /// @param bonus `b`, Aave's liquidation bonus (10⁴ = no bonus).
    /// @param liquidationFee `lf`, Aave's liquidation fee, bps.
    function netBonus(
        uint256 bonus,
        uint256 liquidationFee
    ) internal pure returns (uint256) {
        if (bonus <= BPS || liquidationFee >= BPS) return BPS;
        return BPS + (bonus - BPS) * (BPS - liquidationFee) / BPS;
    }

    /// @notice Effective slippage `s = min(allowance, ⌊10⁴ × (bNet − 10⁴) / bNet⌋)` if `bNet > 10⁴`, else 0.
    function effectiveSlippage(
        uint256 bNet,
        uint256 allowanceBps
    ) internal pure returns (uint256) {
        if (bNet <= BPS) return 0;
        uint256 cap = BPS * (bNet - BPS) / bNet;
        return allowanceBps < cap ? allowanceBps : cap;
    }

    /// @notice Leg slippage with the caller's top-up: `min(9999, s + min(maxShortfallBps, ⌊maxShortfall × 10⁴ / V⌋))`.
    function legSlippage(
        uint256 slippage,
        uint256 maxShortfall,
        uint256 value,
        uint256 maxShortfallBps
    ) internal pure returns (uint256) {
        if (slippage >= MAX_LEG_SLIPPAGE_BPS) return MAX_LEG_SLIPPAGE_BPS;
        uint256 relax = 0;
        if (maxShortfall != 0 && value != 0) {
            // maxShortfall ≥ V makes the exact quotient ≥ 10⁴, which every outcome of the two `min`s treats alike.
            relax = maxShortfall >= value ? BPS : Math.mulDiv(maxShortfall, BPS, value);
            if (relax > maxShortfallBps) relax = maxShortfallBps;
        }
        // slippage < 9,999 here; relax ≥ 9,999 − slippage saturates without overflow.
        if (relax >= MAX_LEG_SLIPPAGE_BPS - slippage) return MAX_LEG_SLIPPAGE_BPS;
        return slippage + relax;
    }

    /// @notice Leg slippage of `settlePending`, `min(slippageAllowanceBps, 30)`.
    function pendingSlippage(
        uint256 allowanceBps
    ) internal pure returns (uint256) {
        return allowanceBps < PENDING_SLIPPAGE_CAP_BPS ? allowanceBps : PENDING_SLIPPAGE_CAP_BPS;
    }

    /// @notice Seized oracle value `mulDiv(units × Pc, 10^dd, 10^dv × Pdebt)`, rounded down; prices 8-decimal USD.
    function seizedValue(
        uint256 units,
        uint256 collateralPrice,
        uint8 vaultDecimals,
        uint8 debtDecimals,
        uint256 debtPrice
    ) internal pure returns (uint256) {
        return _value(units, collateralPrice, vaultDecimals, debtDecimals, debtPrice, Math.Rounding.Floor);
    }

    /// @notice Leg oracle value `Vleg = mulDiv(a × p, 10^dd, 10^d × Pdebt)`, rounded down.
    function legValue(
        uint256 amount,
        uint256 price,
        uint8 tokenDecimals,
        uint8 debtDecimals,
        uint256 debtPrice
    ) internal pure returns (uint256) {
        return _value(amount, price, tokenDecimals, debtDecimals, debtPrice, Math.Rounding.Floor);
    }

    /// @notice One term of the pending value, `⌈mulDiv(a × p, 10^dp, 10^d × Pp)⌉`, rounded up.
    function pendingLegValue(
        uint256 amount,
        uint256 price,
        uint8 tokenDecimals,
        uint8 pendingDecimals,
        uint256 pendingPrice
    ) internal pure returns (uint256) {
        return _value(amount, price, tokenDecimals, pendingDecimals, pendingPrice, Math.Rounding.Ceil);
    }

    /// @notice Value of one raw unit of a released token, `⌈p × 10^dd / (10^d × Pdebt)⌉`, at least 1.
    function unitValue(
        uint256 price,
        uint8 tokenDecimals,
        uint8 debtDecimals,
        uint256 debtPrice
    ) internal pure returns (uint256) {
        return _value(1, price, tokenDecimals, debtDecimals, debtPrice, Math.Rounding.Ceil);
    }

    /// @notice Recovery floor `max(0, ⌈value × (10⁴ − slippage) / 10⁴⌉ − units − allowance)`.
    /// @param units Sum of the released tokens' unit values.
    function recoveryFloor(
        uint256 value,
        uint256 slippage,
        uint256 units,
        uint256 allowance
    ) internal pure returns (uint256) {
        return _subFloor(Math.ceilDiv(value * (BPS - slippage), BPS), units, allowance);
    }

    /// @notice Whether a released leg is a dust leg, `Vleg ≤ Uleg`: it is not swapped and has no minimum.
    function isDustLeg(
        uint256 legValue_,
        uint256 legUnit
    ) internal pure returns (bool) {
        return legValue_ <= legUnit;
    }

    /// @notice Per-leg minimum output `max(1, ⌈Vleg × (10⁴ − sLeg) / 10⁴⌉ − Uleg − ⌊allowance / swappedLegs⌋)`.
    function legMinOut(
        uint256 legValue_,
        uint256 sLeg,
        uint256 legUnit,
        uint256 allowance,
        uint256 swappedLegs
    ) internal pure returns (uint256) {
        uint256 out = _subFloor(Math.ceilDiv(legValue_ * (BPS - sLeg), BPS), legUnit, allowance / swappedLegs);
        return out == 0 ? 1 : out;
    }

    /// @notice Recovery the waterfall splits, `max(R, minRec)`; top-up above the floor never counts as surplus.
    function recoveryWithFloor(
        uint256 minRec,
        uint256 recovered
    ) internal pure returns (uint256) {
        return recovered > minRec ? recovered : minRec;
    }

    /// @notice Settlement gap `max(0, D + A + B − Kf − R)` the caller pays inside `shortfall`.
    function roundingGap(
        uint256 debtRepaid,
        uint256 avanaFee,
        uint256 borrowerSurplus,
        uint256 callerFunds,
        uint256 recovered
    ) internal pure returns (uint256) {
        return _subFloor(debtRepaid + avanaFee + borrowerSurplus, callerFunds, recovered);
    }

    /// @notice The caller's top-up `max(0, minRec − R, gap)`; reverts if either term exceeds `maxShortfall`.
    function shortfallTopUp(
        uint256 minRec,
        uint256 recovered,
        uint256 gap,
        uint256 maxShortfall
    ) internal pure returns (uint256 shortfall) {
        shortfall = minRec > recovered ? minRec - recovered : 0;
        if (shortfall > maxShortfall) revert ILPVaultSwapErrors.RecoveryBelowFloor();
        if (gap > maxShortfall) revert ILPVaultSwapErrors.InsufficientProceeds();
        if (gap > shortfall) shortfall = gap;
    }

    /// @notice Surplus, oracle gain and their split into Avana's fee, the keeper reward and the borrower surplus.
    function payouts(
        uint256 value,
        uint256 debtRepaid,
        uint256 recoveredWithFloor,
        uint256 feeShareBps
    ) internal pure returns (Payouts memory p) {
        if (feeShareBps > BPS) revert ILPVaultSwapErrors.InvalidFeeShare(feeShareBps);
        p.surplus = _subFloor(recoveredWithFloor, debtRepaid, 0);
        p.oracleGain = _subFloor(value, debtRepaid, 0);
        uint256 feeOnGain = p.oracleGain * feeShareBps / BPS;
        p.avanaFee = feeOnGain < p.surplus ? feeOnGain : p.surplus;
        p.keeperReward = (p.surplus < p.oracleGain ? p.surplus : p.oracleGain) - p.avanaFee;
        p.borrowerSurplus = p.surplus - p.avanaFee - p.keeperReward;
    }

    /// @notice Caller payout `(Kf + R') − (D + A + B)`; reverts `InsufficientProceeds` if negative.
    function keeperPayout(
        uint256 callerFunds,
        uint256 recoveredWithTopUp,
        uint256 debtRepaid,
        uint256 avanaFee,
        uint256 borrowerSurplus
    ) internal pure returns (uint256) {
        uint256 inflow = callerFunds + recoveredWithTopUp;
        uint256 outflow = debtRepaid + avanaFee + borrowerSurplus;
        if (inflow < outflow) revert ILPVaultSwapErrors.InsufficientProceeds();
        return inflow - outflow;
    }

    /// @notice Flash premium bound `premium × 10⁴ ≤ maxFlashFeeBps × amount`, exact for every input.
    function flashPremiumWithinCap(
        uint256 premium,
        uint256 amount,
        uint256 maxFlashFeeBps
    ) internal pure returns (bool) {
        // For integer φ: φ·10⁴ ≤ m·F ⇔ φ ≤ ⌊m·F/10⁴⌋ ⇔ ⌈φ·10⁴/m⌉ ≤ F; each quotient is at most max(F, φ).
        if (maxFlashFeeBps <= BPS) return premium <= Math.mulDiv(maxFlashFeeBps, amount, BPS);
        return Math.mulDiv(premium, BPS, maxFlashFeeBps, Math.Rounding.Ceil) <= amount;
    }

    /// @notice Repayment cap of `deleverage`: the net value after slippage, rounding and the most flash fee.
    function deleverageCap(
        uint256 value,
        uint256 slippage,
        uint256 units,
        uint256 allowance,
        uint256 maxFlashFeeBps
    ) internal pure returns (uint256) {
        return _subFloor(value * (BPS - slippage) / BPS, units, allowance) * BPS / (BPS + maxFlashFeeBps);
    }

    /// @notice Repayment `min(debt, cap)`; reverts `DeleverageTooSmall` if 0 or below `minDebtRepaid`.
    function deleverageRepayment(
        uint256 debt,
        uint256 cap,
        uint256 minDebtRepaid
    ) internal pure returns (uint256 x) {
        x = debt < cap ? debt : cap;
        if (x == 0 || x < minDebtRepaid) revert ILPVaultSwapErrors.DeleverageTooSmall(x, minDebtRepaid);
    }

    /// @notice Debt asset left to the borrower, `recovered − repaid − premium`; reverts `DeleverageShortfall` if < 0.
    function deleverageAssetOut(
        uint256 recovered,
        uint256 repaid,
        uint256 premium
    ) internal pure returns (uint256) {
        uint256 owed = repaid + premium;
        if (recovered < owed) revert ILPVaultSwapErrors.DeleverageShortfall(recovered, owed);
        return recovered - owed;
    }

    /// @dev `amount × price × 10^to / (10^from × quotePrice)` with one 512-bit `mulDiv`.
    function _value(
        uint256 amount,
        uint256 price,
        uint8 fromDecimals,
        uint8 toDecimals,
        uint256 quotePrice,
        Math.Rounding rounding
    ) private pure returns (uint256) {
        if (fromDecimals > MAX_DECIMALS) revert ILPVaultSwapErrors.InvalidDecimals(fromDecimals);
        if (toDecimals > MAX_DECIMALS) revert ILPVaultSwapErrors.InvalidDecimals(toDecimals);
        if (price == 0) revert ILPVaultSwapErrors.ZeroCollateralPrice();
        if (quotePrice == 0) revert ILPVaultSwapErrors.ZeroDebtPrice();
        return Math.mulDiv(amount, price * 10 ** toDecimals, 10 ** fromDecimals * quotePrice, rounding);
    }

    /// @dev `max(0, a − b − c)` without forming `b + c`.
    function _subFloor(
        uint256 a,
        uint256 b,
        uint256 c
    ) private pure returns (uint256) {
        if (a <= b) return 0;
        a -= b;
        return a > c ? a - c : 0;
    }
}
// forge-lint: disable-end(require-revert-in-loop)
