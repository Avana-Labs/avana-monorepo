// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SettlementMath} from "../../../src/liquidation/lp-vault-swap/SettlementMath.sol";

/// @title SettlementMathProperties
/// @notice Echidna and Medusa properties of `SettlementMath`, in base units of the repaid debt asset: the 2.11 worked
/// examples hold, and for every bounded input the waterfall splits the surplus exactly and conserves the debt asset,
/// the effective slippage keeps the bonus inequality, the floors and leg minimums round against the caller and are
/// never 0 on a swapped leg, a completed top-up closes the floor and the rounding gap, the flash bound is the exact
/// inequality and the repay-with-collateral repayment plus its premium stays within the units' net value.
/// @dev `property_` functions run in property mode; every other public function is an assertion entry point whose
/// inputs are reduced by `%` into the listing bounds, with no loop, so hevm can prove each one.
contract SettlementMathProperties {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant B128 = 2 ** 128;

    /// @notice Number of assertion calls made; written so each call is a transaction.
    uint256 public checks;

    function property_waterfallExampleHolds() external pure returns (bool) {
        SettlementMath.Payouts memory p = SettlementMath.payouts(2_047_500_000, 1_950_000_000, 2_040_300_000, 2000);
        uint256 out = SettlementMath.keeperPayout(1_950_000_000, 2_040_300_000, 1_950_000_000, p.avanaFee, 0);
        return p.surplus == 90_300_000 && p.avanaFee == 19_500_000 && p.keeperReward == 70_800_000
            && p.borrowerSurplus == 0 && out == 2_020_800_000;
    }

    function property_floorExampleHolds() external pure returns (bool) {
        uint256 v = SettlementMath.seizedValue(975e18, 210_000_000, 18, 6, 1e8);
        uint256 u = 1 + SettlementMath.unitValue(99_950_000, 6, 6, 1e8);
        return v == 2_047_500_000 && SettlementMath.recoveryFloor(v, 100, u, 1e6) == 2_026_024_998;
    }

    function property_slippageExampleHolds() external pure returns (bool) {
        uint256 s = SettlementMath.effectiveSlippage(SettlementMath.netBonus(10_500, 0), 100);
        return s == 100 && SettlementMath.effectiveSlippage(10_050, 1000) == 49;
    }

    function property_legMinimumExampleHolds() external pure returns (bool) {
        uint256 vLeg = SettlementMath.legValue(6_211_300_000, 99_950_000, 6, 6, 1e8);
        return SettlementMath.legMinOut(vLeg, 100, 1, 1e6, 1) == 6_145_112_406
            && SettlementMath.legSlippage(100, 200e6, 12_422_600_000, 1000) == 260;
    }

    /// @notice `A + kr + B == S`, `A ≤ S`, `B == max(0, S − G)`, and a completed call conserves the debt asset.
    function waterfall(
        uint256 value,
        uint256 debt,
        uint256 rp,
        uint256 share,
        uint256 callerFunds
    ) public {
        value %= B128;
        debt %= B128;
        rp %= B128;
        share %= BPS + 1;
        callerFunds %= B128;
        SettlementMath.Payouts memory p = SettlementMath.payouts(value, debt, rp, share);
        assert(p.avanaFee + p.keeperReward + p.borrowerSurplus == p.surplus);
        assert(p.avanaFee <= p.surplus);
        assert(p.borrowerSurplus == (p.surplus > p.oracleGain ? p.surplus - p.oracleGain : 0));
        uint256 outflow = debt + p.avanaFee + p.borrowerSurplus;
        uint256 inflow = callerFunds + rp;
        if (inflow >= outflow) {
            uint256 out = SettlementMath.keeperPayout(callerFunds, rp, debt, p.avanaFee, p.borrowerSurplus);
            assert(inflow == outflow + out);
        }
        ++checks;
    }

    /// @notice For every bonus: `bNet ≥ 10⁴`, `s ≤ allowance`, and `bNet × (10⁴ − s) ≥ 10⁸` whenever `bNet > 10⁴`.
    function slippage(
        uint256 bonus,
        uint256 liquidationFee,
        uint256 allowance
    ) public {
        bonus %= 2 ** 32;
        liquidationFee %= 2 * BPS + 1;
        allowance %= BPS + 1;
        uint256 bNet = SettlementMath.netBonus(bonus, liquidationFee);
        uint256 s = SettlementMath.effectiveSlippage(bNet, allowance);
        assert(bNet >= BPS && s <= allowance && s < BPS);
        if (bNet > BPS) assert(bNet * (BPS - s) >= BPS * BPS);
        else assert(s == 0);
        ++checks;
    }

    /// @notice The slippage term is the net oracle value rounded up (at least it, less than it plus 1); the floor is
    /// that term less `U + ε`, so with at least one rounding unit (`U` is one raw unit per released token in every
    /// liquidation, as in `check_PROP_048_floorWithRoundingTerms`) it is at most the net oracle value; a leg minimum
    /// is in `[max(1, floor), max(1, Vleg)]`.
    function floors(
        uint256 value,
        uint256 s,
        uint256 units,
        uint256 allowance,
        uint256 legs
    ) public {
        value %= 2 ** 200;
        s %= BPS + 1;
        units %= B128;
        allowance %= B128;
        legs = legs % 4 + 1;
        uint256 exact = value * (BPS - s);
        uint256 gross = SettlementMath.recoveryFloor(value, s, 0, 0);
        uint256 minRec = SettlementMath.recoveryFloor(value, s, units, allowance);
        assert(gross * BPS >= exact && gross * BPS < exact + BPS);
        assert(minRec <= gross && minRec + units + allowance >= gross);
        if (units + allowance != 0) assert(minRec * BPS <= exact);
        uint256 minOut = SettlementMath.legMinOut(value, s, units, allowance, legs);
        assert(minOut >= 1 && minOut >= minRec && minOut <= (value > 1 ? value : 1));
        ++checks;
    }

    /// @notice A top-up within `maxShortfall` leaves `R + shortfall ≥ minRec` and `Kf + R + shortfall ≥ D + A + B`.
    function topUp(
        uint256 minRec,
        uint256 recovered,
        uint256 debt,
        uint256 due,
        uint256 callerFunds,
        uint256 maxShortfall
    ) public {
        minRec %= B128;
        recovered %= B128;
        debt %= B128;
        due %= B128;
        callerFunds %= B128;
        maxShortfall %= 2 ** 129;
        // `due` stands for the payouts A + B already owed from the recovery.
        uint256 gap = SettlementMath.roundingGap(debt, due, 0, callerFunds, recovered);
        assert(callerFunds + recovered + gap >= debt + due);
        uint256 floorGap = minRec > recovered ? minRec - recovered : 0;
        if (floorGap <= maxShortfall && gap <= maxShortfall) {
            uint256 shortfall = SettlementMath.shortfallTopUp(minRec, recovered, gap, maxShortfall);
            assert(shortfall <= maxShortfall && recovered + shortfall >= minRec);
            assert(callerFunds + recovered + shortfall >= debt + due);
        }
        ++checks;
    }

    /// @notice The flash bound equals the exact inequality `φ × 10⁴ ≤ maxFlashFeeBps × amount`.
    function flashBound(
        uint256 premium,
        uint256 amount,
        uint256 maxFlashFeeBps
    ) public {
        premium %= B128;
        amount %= B128;
        maxFlashFeeBps %= 2 * BPS + 1;
        assert(
            SettlementMath.flashPremiumWithinCap(premium, amount, maxFlashFeeBps)
                == (premium * BPS <= maxFlashFeeBps * amount)
        );
        ++checks;
    }

    /// @notice The repayment `x` and a premium within the cap fit in `Vnet`, and `x` never exceeds the debt.
    function deleverage(
        uint256 value,
        uint256 s,
        uint256 units,
        uint256 maxFlashFeeBps,
        uint256 debt
    ) public {
        value %= 2 ** 200;
        s %= BPS + 1;
        units %= B128;
        maxFlashFeeBps %= 101;
        debt = debt % B128 + 1;
        uint256 allowance = units / 3;
        uint256 cap = SettlementMath.deleverageCap(value, s, units, allowance, maxFlashFeeBps);
        uint256 gross = value * (BPS - s) / BPS;
        uint256 vnet = gross > units + allowance ? gross - units - allowance : 0;
        assert(cap * (BPS + maxFlashFeeBps) <= vnet * BPS);
        if (cap > 0) {
            uint256 x = SettlementMath.deleverageRepayment(debt, cap, 0);
            assert(x <= debt && x <= cap && x + x * maxFlashFeeBps / BPS <= vnet);
        }
        ++checks;
    }
}
