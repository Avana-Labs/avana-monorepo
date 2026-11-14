// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "./ILPVaultSwapErrors.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// The valuation checks (decimals, zero prices) revert inside the callers' leg loops by design: a token with an
// invalid price or decimals must stop the settlement (SPEC-LIQ-004).
// forge-lint: disable-start(require-revert-in-loop)
/// @title SettlementMath
/// @notice The settlement arithmetic of a liquidation, in base units of the repaid debt asset `T`: net bonus and
/// effective slippage; oracle values of the seizure, of each released leg and of one raw unit; the recovery
/// floor and the pending-settlement floor; each leg's oracle-derived minimum output; the caller's shortfall top-up and
/// settlement gap; the waterfall into Avana's fee, the keeper reward and the borrower surplus; the caller's payout; the
/// flash premium bound; and repay-with-collateral sizing.
/// @dev Internal library of LPVaultSwap (`Q-240`): pure functions, no storage, no external call. Each rounding goes
/// against the caller: the seizure and leg values down, the pending value up (it raises the floor that protects the
/// First-Loss Reserve), slippage terms up, unit values up, Avana's fee down, the repay-with-collateral cap down. A zero
/// price reverts with `ZeroCollateralPrice` or `ZeroDebtPrice`, decimals above 36 with `InvalidDecimals`, and a fee
/// share above 10^4 with `InvalidFeeShare`. Products that the listing bounds keep below 2^256 use checked arithmetic
/// (a value beyond the bound panics, so the liquidation reverts); the oracle-value products, whose operands can reach
/// 2^244, use OpenZeppelin `Math.mulDiv`. Bounds: amounts, `V` and the flash premium below 2^200, waterfall terms
/// below 2^129, Aave's bonus below 2^32, 8-decimal prices below 2^64, bps arguments at most 10^4 (`maxShortfallBps`
/// at most 5,000, `maxFlashFeeBps` at most 100).
/// No liquidation function has a flash principal, flash premium or transfer-fee term: `liquidate` takes no flash loan
/// (`Q-404`), so `s` has no premium term, `g = max(0, D + A + B − Kf − R)` and `keeperOut = Kf + R' − D − A − B`, with
/// `Kf` the caller funding measured by balance delta. Only the `deleverage` sizing carries the flash fee cap and premium.
/// @custom:spec SPEC-LIQ-001, SPEC-LIQ-002, SPEC-LIQ-003, SPEC-LIQ-004, SPEC-LIQ-005, SPEC-LIQ-008, SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-014, SPEC-LIQ-015, SPEC-LIQ-018, SPEC-LIQ-019, SPEC-LIQ-020, SPEC-LIQ-022, SPEC-SET-001, REQ-SWAP-100, REQ-SWAP-121, INV-034, INV-035, INV-036, INV-083, INV-086, Q-240, Q-404
library SettlementMath {
    /// @notice 100 % in basis points.
    uint256 internal constant BPS = 10_000;

    /// @notice Largest slippage a leg may run at when the caller's shortfall top-up relaxes it (`SPEC-LIQ-019`).
    uint256 internal constant MAX_LEG_SLIPPAGE_BPS = 9999;

    /// @notice Cap on the leg slippage of `settlePending` (`SPEC-LIQ-014`).
    uint256 internal constant PENDING_SLIPPAGE_CAP_BPS = 30;

    /// @notice Most token decimals a valuation accepts (`SPEC-LIQ-004`).
    uint8 internal constant MAX_DECIMALS = 36;

    /// @notice The split of the realized surplus `S` (`SPEC-LIQ-008`, `SPEC-LIQ-009`, `SPEC-LIQ-022`).
    /// @param surplus `S = max(0, R_f − D)`, with `R_f = max(R, minRec)`.
    /// @param oracleGain `G = max(0, V − D)`.
    /// @param avanaFee `A = min(⌊G × avanaFeeShareBps / 10⁴⌋, S)`.
    /// @param keeperReward `kr = min(S, G) − A`.
    /// @param borrowerSurplus `B = S − A − kr`.
    struct Payouts {
        uint256 surplus;
        uint256 oracleGain;
        uint256 avanaFee;
        uint256 keeperReward;
        uint256 borrowerSurplus;
    }

    // ----------------------------------------------------------------------------------------------- bonus and slippage

    /// @notice Net bonus `bNet = 10⁴ + ⌊(b − 10⁴) × (10⁴ − lf) / 10⁴⌋` bps, rounded down; `10⁴` when `b ≤ 10⁴` or
    /// `lf ≥ 10⁴`.
    /// @param bonus `b`, Aave's liquidation bonus (10⁴ = no bonus).
    /// @param liquidationFee `lf`, Aave's liquidation fee of the collateral reserve, bps.
    /// @custom:spec SPEC-LIQ-001
    function netBonus(
        uint256 bonus,
        uint256 liquidationFee
    ) internal pure returns (uint256) {
        if (bonus <= BPS || liquidationFee >= BPS) return BPS;
        return BPS + (bonus - BPS) * (BPS - liquidationFee) / BPS;
    }

    /// @notice Effective slippage `s = min(allowance, ⌊10⁴ × (bNet − 10⁴) / bNet⌋)` if `bNet > 10⁴`, else 0; rounded
    /// down. Always below 10⁴. A liquidation has no cost term (`SPEC-LIQ-002`): it takes no flash loan.
    /// @param bNet Net bonus from `netBonus`.
    /// @param allowanceBps The market's `slippageAllowanceBps`.
    /// @custom:spec SPEC-LIQ-002, SPEC-LIQ-003, SPEC-LIQ-016
    function effectiveSlippage(
        uint256 bNet,
        uint256 allowanceBps
    ) internal pure returns (uint256) {
        if (bNet <= BPS) return 0;
        uint256 cap = BPS * (bNet - BPS) / bNet;
        return allowanceBps < cap ? allowanceBps : cap;
    }

    /// @notice Leg slippage of a liquidation with the caller's top-up:
    /// `sLeg = min(9,999, s + min(maxShortfallBps, ⌊maxShortfall × 10⁴ / V⌋))`, the added term 0 when
    /// `maxShortfall = 0` or `V = 0`; the relaxation term rounded down.
    /// @param slippage `s` from `effectiveSlippage`.
    /// @param maxShortfall The call's `maxShortfall`, debt units.
    /// @param value `V` from `seizedValue`.
    /// @param maxShortfallBps The chain's `maxShortfallBps`.
    /// @custom:spec SPEC-LIQ-019
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

    /// @notice Leg slippage of `settlePending`, `s_P = min(slippageAllowanceBps, 30)`.
    /// @param allowanceBps The market's `slippageAllowanceBps`.
    /// @custom:spec SPEC-LIQ-014
    function pendingSlippage(
        uint256 allowanceBps
    ) internal pure returns (uint256) {
        return allowanceBps < PENDING_SLIPPAGE_CAP_BPS ? allowanceBps : PENDING_SLIPPAGE_CAP_BPS;
    }

    // ----------------------------------------------------------------------------------------------------- oracle values

    /// @notice Seized oracle value `V = mulDiv(c × Pc, 10^dd, 10^dv × Pdebt)`, rounded down; the same formula sizes
    /// `deleverage` with `units` in place of `c`. Reverts with `InvalidDecimals` if a decimals value exceeds 36, then
    /// with `ZeroCollateralPrice` if `Pc = 0`, then with `ZeroDebtPrice` if `Pdebt = 0`.
    /// @param units `c`, vault-token base units.
    /// @param collateralPrice `Pc`, 8-decimal USD.
    /// @param vaultDecimals `dv`.
    /// @param debtDecimals `dd`.
    /// @param debtPrice `Pdebt`, 8-decimal USD.
    /// @custom:spec SPEC-LIQ-004, SPEC-LIQ-020
    function seizedValue(
        uint256 units,
        uint256 collateralPrice,
        uint8 vaultDecimals,
        uint8 debtDecimals,
        uint256 debtPrice
    ) internal pure returns (uint256) {
        return _value(units, collateralPrice, vaultDecimals, debtDecimals, debtPrice, Math.Rounding.Floor);
    }

    /// @notice Leg oracle value `Vleg = mulDiv(a × p, 10^dd, 10^d × Pdebt)`, rounded down; reverts as `seizedValue`.
    /// @param amount `aᵢ`, raw units of the released token.
    /// @param price `pᵢ`, the token's capped 8-decimal leg price.
    /// @param tokenDecimals `dᵢ`.
    /// @param debtDecimals `dd` (`dp` in a pending settlement).
    /// @param debtPrice `Pdebt` (`Pp`).
    /// @custom:spec SPEC-LIQ-004, SPEC-LIQ-018, REQ-SWAP-121
    function legValue(
        uint256 amount,
        uint256 price,
        uint8 tokenDecimals,
        uint8 debtDecimals,
        uint256 debtPrice
    ) internal pure returns (uint256) {
        return _value(amount, price, tokenDecimals, debtDecimals, debtPrice, Math.Rounding.Floor);
    }

    /// @notice One term of the pending value `V_P = Σᵢ ⌈mulDiv(aᵢ × pᵢ, 10^dp, 10^dᵢ × Pp)⌉`, rounded up; reverts as
    /// `seizedValue`.
    /// @param amount `aᵢ`, raw units released by `Collateralization.settlePending`.
    /// @param price `pᵢ`, 8-decimal leg price.
    /// @param tokenDecimals `dᵢ`.
    /// @param pendingDecimals `dp`.
    /// @param pendingPrice `Pp`.
    /// @custom:spec SPEC-LIQ-004, SPEC-LIQ-014
    function pendingLegValue(
        uint256 amount,
        uint256 price,
        uint8 tokenDecimals,
        uint8 pendingDecimals,
        uint256 pendingPrice
    ) internal pure returns (uint256) {
        return _value(amount, price, tokenDecimals, pendingDecimals, pendingPrice, Math.Rounding.Ceil);
    }

    /// @notice Value of one raw unit of a released token, `⌈p × 10^dd / (10^d × Pdebt)⌉`, at least 1 (a positive price
    /// always gives at least 1); reverts as `seizedValue`. A token that is `T` itself counts 1: the caller passes 1 for
    /// it instead of calling this function.
    /// @param price `pᵢ`, 8-decimal leg price.
    /// @param tokenDecimals `dᵢ`.
    /// @param debtDecimals `dd`.
    /// @param debtPrice `Pdebt`.
    /// @custom:spec SPEC-LIQ-004, SPEC-LIQ-005, SPEC-LIQ-018
    function unitValue(
        uint256 price,
        uint8 tokenDecimals,
        uint8 debtDecimals,
        uint256 debtPrice
    ) internal pure returns (uint256) {
        return _value(1, price, tokenDecimals, debtDecimals, debtPrice, Math.Rounding.Ceil);
    }

    // ------------------------------------------------------------------------------------------- floors and leg minimums

    /// @notice Recovery floor `minRec = max(0, ⌈V × (10⁴ − s) / 10⁴⌉ − U − ε)`; with `V_P`, `s_P` it is
    /// `minPending`. The slippage term rounds up; the subtraction saturates at 0.
    /// @param value `V` (or `V_P`), below 2^200.
    /// @param slippage `s` (or `s_P`), at most 10⁴.
    /// @param units `U = Σᵢ unitValue(pᵢ)` over the released tokens.
    /// @param allowance `ε = floorRoundingAllowance(spoke, r)`.
    /// @custom:spec SPEC-LIQ-005, SPEC-LIQ-014, INV-034
    function recoveryFloor(
        uint256 value,
        uint256 slippage,
        uint256 units,
        uint256 allowance
    ) internal pure returns (uint256) {
        return _subFloor(Math.ceilDiv(value * (BPS - slippage), BPS), units, allowance);
    }

    /// @notice Whether a released leg is a dust leg, `Vleg ≤ Uleg`: it is not swapped and has no minimum.
    /// @param legValue_ `Vlegᵢ` from `legValue`.
    /// @param legUnit `Ulegᵢ` from `unitValue`.
    /// @custom:spec REQ-SWAP-121, SPEC-LIQ-018
    function isDustLeg(
        uint256 legValue_,
        uint256 legUnit
    ) internal pure returns (bool) {
        return legValue_ <= legUnit;
    }

    /// @notice Per-leg minimum output `minOutᵢ = max(1, ⌈Vleg × (10⁴ − sLeg) / 10⁴⌉ − Uleg − ⌊ε / n'⌋)`, never 0.
    /// @param legValue_ `Vlegᵢ`, below 2^200.
    /// @param sLeg The call's leg slippage, at most 10⁴.
    /// @param legUnit `Ulegᵢ`.
    /// @param allowance `ε`.
    /// @param swappedLegs `n'`, the number of legs the call swaps; at least 1 for a leg that is swapped (0 reverts).
    /// @custom:spec SPEC-LIQ-018, REQ-SWAP-100, INV-083
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

    // ------------------------------------------------------------------------------------------------ shortfall top-up

    /// @notice Recovery the waterfall splits, `R_f = max(R, minRec)`: the recovery plus the floor part of the caller's
    /// top-up. The part of the top-up above the floor pays the settlement gap and never counts as surplus.
    /// @param minRec The recovery floor.
    /// @param recovered `R`.
    /// @custom:spec SPEC-LIQ-008, SPEC-LIQ-019
    function recoveryWithFloor(
        uint256 minRec,
        uint256 recovered
    ) internal pure returns (uint256) {
        return recovered > minRec ? recovered : minRec;
    }

    /// @notice Settlement gap `g = max(0, D + A + B − Kf − R)`: what the caller pays inside `shortfall` so that its own
    /// funding and the recovery cover the debt and the payouts already due from the recovery. `A` and `B` come from
    /// `payouts` on `R_f`. Because `D ≤ Kf`, `g` never exceeds the floor gap `max(0, minRec − R)` (`SPEC-LIQ-019`).
    /// @param debtRepaid `D`.
    /// @param avanaFee `A`.
    /// @param borrowerSurplus `B`.
    /// @param callerFunds `Kf`, the caller funding measured by balance delta.
    /// @param recovered `R`.
    /// @custom:spec SPEC-SET-001, SPEC-LIQ-019, REQ-SWAP-029
    function roundingGap(
        uint256 debtRepaid,
        uint256 avanaFee,
        uint256 borrowerSurplus,
        uint256 callerFunds,
        uint256 recovered
    ) internal pure returns (uint256) {
        return _subFloor(debtRepaid + avanaFee + borrowerSurplus, callerFunds, recovered);
    }

    /// @notice The caller's top-up `shortfall = max(0, minRec − R, g)`. Reverts with `RecoveryBelowFloor` if
    /// `minRec − R > maxShortfall`, then with `InsufficientProceeds` if `g > maxShortfall`.
    /// @param minRec The recovery floor.
    /// @param recovered `R`.
    /// @param gap `g` from `roundingGap`.
    /// @param maxShortfall The call's `maxShortfall`.
    /// @custom:spec SPEC-LIQ-019, SPEC-SET-001, REQ-SWAP-025, REQ-SWAP-060, REQ-SWAP-061, REQ-SWAP-101, INV-034
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

    // ------------------------------------------------------------------------------------------------------- waterfall

    /// @notice Surplus, oracle gain and their split: `S = max(0, R_f − D)`, `G = max(0, V − D)`,
    /// `A = min(⌊G × avanaFeeShareBps / 10⁴⌋, S)`, `kr = min(S, G) − A`, `B = S − A − kr = max(0, S − G)`.
    /// `A + kr + B = S` for every input. Reverts with `InvalidFeeShare` if `avanaFeeShareBps > 10⁴`; within it
    /// `A ≤ min(S, G)`, so `kr` never saturates.
    /// @param value `V`, below 2^200.
    /// @param debtRepaid `D`.
    /// @param recoveredWithFloor `R_f = max(R, minRec)` from `recoveryWithFloor`.
    /// @param feeShareBps `avanaFeeShareBps`.
    /// @custom:spec SPEC-LIQ-007, SPEC-LIQ-008, SPEC-LIQ-009, SPEC-LIQ-022, INV-036, INV-086
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

    /// @notice Caller payout `keeperOut = (Kf + R') − (D + A + B)`; reverts with `InsufficientProceeds` if the first
    /// sum is smaller (defensive: `D ≤ Kf` and `A + B ≤ max(0, R' − D)` keep it non-negative). `Kf` is the measured
    /// funding; a transfer fee on `T` itself reverts in Aave V4's Hub before this runs (REQ-SWAP-123).
    /// @param callerFunds `Kf`.
    /// @param recoveredWithTopUp `R' = R + shortfall`.
    /// @param debtRepaid `D`.
    /// @param avanaFee `A`.
    /// @param borrowerSurplus `B`.
    /// @custom:spec SPEC-LIQ-010, REQ-SWAP-026, REQ-SWAP-062, INV-035
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

    // ------------------------------------------------------------------------------------------------------ flash bound

    /// @notice Flash premium bound `φ × 10⁴ ≤ maxFlashFeeBps × amount`, exact for every input: the 512-bit `mulDiv`
    /// never overflows and no rounding enters the comparison.
    /// @param premium The premium quoted (pre-loan) or charged (callback).
    /// @param amount The flash principal.
    /// @param maxFlashFeeBps The chain's `maxFlashFeeBps`.
    /// @custom:spec SPEC-LIQ-015, REQ-FLASH-002, REQ-SWAP-013
    function flashPremiumWithinCap(
        uint256 premium,
        uint256 amount,
        uint256 maxFlashFeeBps
    ) internal pure returns (bool) {
        // For integer φ: φ·10⁴ ≤ m·F ⇔ φ ≤ ⌊m·F/10⁴⌋ ⇔ ⌈φ·10⁴/m⌉ ≤ F; each quotient is at most max(F, φ).
        if (maxFlashFeeBps <= BPS) return premium <= Math.mulDiv(maxFlashFeeBps, amount, BPS);
        return Math.mulDiv(premium, BPS, maxFlashFeeBps, Math.Rounding.Ceil) <= amount;
    }

    // ------------------------------------------------------------------------------------------- repay with collateral

    /// @notice Repayment cap of `deleverage`: `Vnet = max(0, ⌊V × (10⁴ − s) / 10⁴⌋ − U − ε)` and
    /// `cap = ⌊Vnet × 10⁴ / (10⁴ + maxFlashFeeBps)⌋`, both rounded down. Subtracting `ε` matches the leg minimums,
    /// which each give up `⌊ε / n'⌋`, so legs that meet their minimums cover `x + φ` up to the unwind truncation.
    /// @param value `V` of the units, below 2^200.
    /// @param slippage `s = slippageAllowanceBps` of the market, at most 10⁴.
    /// @param units `U`.
    /// @param allowance `ε = floorRoundingAllowance(spoke, r)`.
    /// @param maxFlashFeeBps The chain's `maxFlashFeeBps`.
    /// @custom:spec SPEC-LIQ-020, INV-089
    function deleverageCap(
        uint256 value,
        uint256 slippage,
        uint256 units,
        uint256 allowance,
        uint256 maxFlashFeeBps
    ) internal pure returns (uint256) {
        return _subFloor(value * (BPS - slippage) / BPS, units, allowance) * BPS / (BPS + maxFlashFeeBps);
    }

    /// @notice Repayment `x = min(debt, cap)`; reverts with `DeleverageTooSmall(x, minDebtRepaid)` if `x = 0` or
    /// `x < minDebtRepaid`.
    /// @param debt `Spoke.getUserTotalDebt(r, proxy)`.
    /// @param cap `deleverageCap(...)`.
    /// @param minDebtRepaid The request's `minDebtRepaid`.
    /// @custom:spec SPEC-LIQ-020, REQ-SWAP-106, REQ-SWAP-116
    function deleverageRepayment(
        uint256 debt,
        uint256 cap,
        uint256 minDebtRepaid
    ) internal pure returns (uint256 x) {
        x = debt < cap ? debt : cap;
        if (x == 0 || x < minDebtRepaid) revert ILPVaultSwapErrors.DeleverageTooSmall(x, minDebtRepaid);
    }

    /// @notice Debt asset left to the borrower, `assetOut = R − x − φ`; reverts with `DeleverageShortfall(R, x + φ)`
    /// if `R < x + φ`.
    /// @param recovered `R`.
    /// @param repaid `x`.
    /// @param premium `φ` on the flash loan of `x`.
    /// @custom:spec SPEC-LIQ-020, REQ-SWAP-106, INV-089
    function deleverageAssetOut(
        uint256 recovered,
        uint256 repaid,
        uint256 premium
    ) internal pure returns (uint256) {
        uint256 owed = repaid + premium;
        if (recovered < owed) revert ILPVaultSwapErrors.DeleverageShortfall(recovered, owed);
        return recovered - owed;
    }

    // -------------------------------------------------------------------------------------------------------- private

    /// @dev `amount × price × 10^to / (10^from × quotePrice)` with one 512-bit `mulDiv`, after the decimals and price
    /// checks (decimals, then the valued price, then the quote price).
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
