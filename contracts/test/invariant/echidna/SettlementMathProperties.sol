// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SettlementMath} from "../../../src/liquidation/lp-vault-swap/SettlementMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SettlementMathProperties
/// @notice Echidna and Medusa properties of `SettlementMath`, in base units of the repaid debt asset: the 2.11 worked
/// examples hold, and for every bounded input the waterfall splits the surplus exactly and conserves the debt asset,
/// the effective slippage keeps the bonus inequality, the floors and leg minimums round against the caller and are
/// never 0 on a swapped leg, a completed top-up closes the floor and the rounding gap, the flash bound is the exact
/// inequality and the repay-with-collateral repayment plus its premium stays within the units' net value.
/// @dev Assertion entry points take the fee share, slippage, bonus and flash fee as concrete cases (a literal per entry
/// point or per `which` branch) with the amounts symbolic, so no assertion multiplies two symbolic values and hevm
/// can explore each one. The `fuzz` entry points only record their inputs over the whole range of the earlier single
/// entry points (any fee share, slippage, bonus, liquidation fee and flash fee in their bounds); the matching
/// `property_` functions check the same assertions on them after every transaction, in Echidna's property mode and in
/// Medusa.
contract SettlementMathProperties {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant B128 = 2 ** 128;

    /// @notice Number of assertion calls made; written so each call is a transaction.
    uint256 public checks;

    /// @notice Inputs of the last `fuzz` call of each formula, as the fuzzer gave them.
    uint256[5] internal _waterfallIn;
    uint256[3] internal _slippageIn;
    uint256[5] internal _floorsIn;
    uint256[3] internal _flashIn;
    uint256[5] internal _deleverageIn;
    uint256[6] internal _topUpIn;

    // ─── Properties ───

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

    /// @notice The waterfall at every fee share in `[0, 10^4]`.
    function property_waterfallSplitsAndConserves() external view returns (bool) {
        uint256[5] memory x = _waterfallIn;
        return _waterfallHolds(x[0] % B128, x[1] % B128, x[2] % B128, x[3] % (BPS + 1), x[4] % B128);
    }

    /// @notice The effective slippage at every bonus below `2^32`, liquidation fee in `[0, 2 × 10^4]` and allowance
    /// in `[0, 10^4]`.
    function property_slippageKeepsBonus() external view returns (bool) {
        uint256[3] memory x = _slippageIn;
        return _slippageHolds(x[0] % 2 ** 32, x[1] % (2 * BPS + 1), x[2] % (BPS + 1));
    }

    /// @notice Floors and leg minimums at every slippage in `[0, 10^4]` and 1 to 4 swapped legs.
    function property_floorsRoundAgainstCaller() external view returns (bool) {
        uint256[5] memory x = _floorsIn;
        return _floorsHolds(x[0] % 2 ** 200, x[1] % (BPS + 1), x[2] % B128, x[3] % B128, x[4] % 4 + 1);
    }

    /// @notice A completed top-up closes the floor and the rounding gap.
    function property_topUpCloses() external view returns (bool) {
        uint256[6] memory x = _topUpIn;
        (uint256 minRec, uint256 recovered, uint256 debt, uint256 due, uint256 callerFunds, uint256 maxShortfall) =
            (x[0] % B128, x[1] % B128, x[2] % B128, x[3] % B128, x[4] % B128, x[5] % 2 ** 129);
        uint256 gap = SettlementMath.roundingGap(debt, due, 0, callerFunds, recovered);
        uint256 floorGap = minRec > recovered ? minRec - recovered : 0;
        if (floorGap > maxShortfall || gap > maxShortfall) return callerFunds + recovered + gap >= debt + due;
        uint256 shortfall = SettlementMath.shortfallTopUp(minRec, recovered, gap, maxShortfall);
        return shortfall <= maxShortfall && recovered + shortfall >= minRec
            && callerFunds + recovered + shortfall >= debt + due;
    }

    /// @notice The flash bound at every flash fee in `[0, 2 × 10^4]`: the exact inequality `φ × 10⁴ ≤ fee × amount`.
    function property_flashBoundExact() external view returns (bool) {
        uint256[3] memory x = _flashIn;
        (uint256 premium, uint256 amount, uint256 fee) = (x[0] % B128, x[1] % B128, x[2] % (2 * BPS + 1));
        return SettlementMath.flashPremiumWithinCap(premium, amount, fee) == (premium * BPS <= fee * amount);
    }

    /// @notice The deleverage cap and repayment at every slippage in `[0, 10^4]` and flash fee in `[0, 100]`.
    function property_deleverageWithinNetValue() external view returns (bool) {
        uint256[5] memory x = _deleverageIn;
        return _deleverageHolds(x[0] % 2 ** 200, x[1] % (BPS + 1), x[2] % B128, x[3] % 101, x[4] % B128 + 1);
    }

    // ─── Full-range inputs for the properties ───

    function fuzzWaterfall(
        uint256 value,
        uint256 debt,
        uint256 rp,
        uint256 share,
        uint256 callerFunds
    ) external {
        _waterfallIn = [value, debt, rp, share, callerFunds];
    }

    function fuzzSlippage(
        uint256 bonus,
        uint256 liquidationFee,
        uint256 allowance
    ) external {
        _slippageIn = [bonus, liquidationFee, allowance];
    }

    function fuzzFloors(
        uint256 value,
        uint256 s,
        uint256 units,
        uint256 allowance,
        uint256 legs
    ) external {
        _floorsIn = [value, s, units, allowance, legs];
    }

    function fuzzFlashBound(
        uint256 premium,
        uint256 amount,
        uint256 maxFlashFeeBps
    ) external {
        _flashIn = [premium, amount, maxFlashFeeBps];
    }

    function fuzzTopUp(
        uint256 minRec,
        uint256 recovered,
        uint256 debt,
        uint256 due,
        uint256 callerFunds,
        uint256 maxShortfall
    ) external {
        _topUpIn = [minRec, recovered, debt, due, callerFunds, maxShortfall];
    }

    function fuzzDeleverage(
        uint256 value,
        uint256 s,
        uint256 units,
        uint256 maxFlashFeeBps,
        uint256 debt
    ) external {
        _deleverageIn = [value, s, units, maxFlashFeeBps, debt];
    }

    // ─── Assertion entry points ───

    /// @notice `A + kr + B == S`, `A ≤ S`, `B == max(0, S − G)`, and a completed call conserves the debt asset, at fee
    /// shares 0, 2,000 (the worked example) and 5,000 (the listing maximum; `property_waterfallSplitsAndConserves`
    /// covers every share up to 10,000), with an oracle value of
    /// `debt + gain` above the debt or one at most the debt (`_checkWaterfall`).
    function waterfall0(
        uint256 gain,
        uint256 debt,
        uint256 rp,
        uint256 callerFunds,
        bool aboveDebt
    ) external {
        _checkWaterfall(gain, debt, rp, 0, callerFunds, aboveDebt);
    }

    function waterfall2000(
        uint256 gain,
        uint256 debt,
        uint256 rp,
        uint256 callerFunds,
        bool aboveDebt
    ) external {
        _checkWaterfall(gain, debt, rp, 2000, callerFunds, aboveDebt);
    }

    function waterfall5000(
        uint256 gain,
        uint256 debt,
        uint256 rp,
        uint256 callerFunds,
        bool aboveDebt
    ) external {
        _checkWaterfall(gain, debt, rp, 5000, callerFunds, aboveDebt);
    }

    /// @notice `bNet ≥ 10⁴`, `s ≤ allowance`, and `bNet × (10⁴ − s) ≥ 10⁸` whenever `bNet > 10⁴`, else `s = 0`. `which`
    /// picks (bonus, liquidation fee): (10,000, 0) no bonus, (10,500, 0) and (10,050, 1,000) from the worked
    /// examples, (10,500, 1,000), (11,000, 5,000), (2^32 − 1, 0) the largest bonus, (15,000, 20,000) a fee above
    /// the bonus.
    function slippage(
        uint8 which,
        uint256 allowance
    ) public {
        allowance %= BPS + 1;
        which %= 7;
        if (which == 0) _checkSlippage(BPS, 0, allowance);
        else if (which == 1) _checkSlippage(10_500, 0, allowance);
        else if (which == 2) _checkSlippage(10_050, 1000, allowance);
        else if (which == 3) _checkSlippage(10_500, 1000, allowance);
        else if (which == 4) _checkSlippage(11_000, 5000, allowance);
        else if (which == 5) _checkSlippage(2 ** 32 - 1, 0, allowance);
        else _checkSlippage(15_000, 2 * BPS, allowance);
    }

    /// @notice The recovery floor, `minRec` and the leg minimum are the spec formulas (`_checkFloorFormulas`) at
    /// slippages 0, 1, 100 (the worked example), 9,999 and 10,000, with 1 to 4 swapped legs.
    /// `property_floorsRoundAgainstCaller` checks at every slippage what follows from them: the slippage term is the
    /// net oracle value rounded up (at least it, less than it plus 1); the floor is that term less `U + ε`, so with at
    /// least one rounding unit (`U` is one raw unit per released token in every liquidation, as in
    /// `check_PROP_048_floorWithRoundingTerms`) it is at most the net oracle value; a leg minimum is in
    /// `[max(1, floor), max(1, Vleg)]`.
    function floors0(
        uint256 value,
        uint256 units,
        uint256 allowance,
        uint256 legs
    ) external {
        _checkFloors(value, 0, units, allowance, legs);
    }

    function floors1(
        uint256 value,
        uint256 units,
        uint256 allowance,
        uint256 legs
    ) external {
        _checkFloors(value, 1, units, allowance, legs);
    }

    function floors100(
        uint256 value,
        uint256 units,
        uint256 allowance,
        uint256 legs
    ) external {
        _checkFloors(value, 100, units, allowance, legs);
    }

    function floors9999(
        uint256 value,
        uint256 units,
        uint256 allowance,
        uint256 legs
    ) external {
        _checkFloors(value, 9999, units, allowance, legs);
    }

    function floors10000(
        uint256 value,
        uint256 units,
        uint256 allowance,
        uint256 legs
    ) external {
        _checkFloors(value, BPS, units, allowance, legs);
    }

    /// @notice The rounding gap closes `Kf + R + gap ≥ D + A + B`, and a top-up within `maxShortfall` is
    /// `max(minRec − R, gap)`, at most `maxShortfall`; `property_topUpCloses` checks that it leaves
    /// `R + shortfall ≥ minRec` and `Kf + R + shortfall ≥ D + A + B` (the solver cannot decide those 128-bit sums).
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
            assert(shortfall == (gap > floorGap ? gap : floorGap));
            assert(shortfall <= maxShortfall);
        }
        ++checks;
    }

    /// @notice The flash bound at flash fees 0, 9, 10 (the default), 100, 10,000, 10,001 and 20,000 bps: within
    /// 10,000 bps a premium passes exactly when it is at most `⌊fee × amount / 10⁴⌋`, above it exactly when
    /// `⌈premium × 10⁴ / fee⌉ ≤ amount`, each of which is the exact inequality `φ × 10⁴ ≤ fee × amount`
    /// (`property_flashBoundExact` checks that form at every fee).
    function flashBound(
        uint256 premium,
        uint256 amount,
        uint8 which
    ) public {
        premium %= B128;
        amount %= B128;
        which %= 7;
        if (which == 0) _checkFlashBound(premium, amount, 0);
        else if (which == 1) _checkFlashBound(premium, amount, 9);
        else if (which == 2) _checkFlashBound(premium, amount, 10);
        else if (which == 3) _checkFlashBound(premium, amount, 100);
        else if (which == 4) _checkFlashBound(premium, amount, BPS);
        else if (which == 5) _checkFlashBound(premium, amount, BPS + 1);
        else _checkFlashBound(premium, amount, 2 * BPS);
        ++checks;
    }

    /// @notice The deleverage cap is `⌊Vnet × 10⁴ / (10⁴ + fee)⌋` with `Vnet = ⌊value × (10⁴ − s) / 10⁴⌋ − U − ε`
    /// floored at 0, and the repayment is `min(debt, cap)`. `which` picks (slippage, flash fee): (0, 0), (100, 10)
    /// the worked example's slippage and the default fee, (100, 100), (9,999, 100) and (10,000, 0).
    /// `property_deleverageWithinNetValue` checks that the repayment plus its premium fits in `Vnet` at every slippage
    /// and fee.
    function deleverage(
        uint256 value,
        uint256 units,
        uint256 debt,
        uint8 which
    ) public {
        value %= 2 ** 200;
        units %= B128;
        debt = debt % B128 + 1;
        which %= 5;
        if (which == 0) _checkDeleverage(value, 0, units, 0, debt);
        else if (which == 1) _checkDeleverage(value, 100, units, 10, debt);
        else if (which == 2) _checkDeleverage(value, 100, units, 100, debt);
        else if (which == 3) _checkDeleverage(value, 9999, units, 100, debt);
        else _checkDeleverage(value, BPS, units, 0, debt);
        ++checks;
    }

    // ─── Helpers ───

    function _waterfallHolds(
        uint256 value,
        uint256 debt,
        uint256 rp,
        uint256 share,
        uint256 callerFunds
    ) internal pure returns (bool ok) {
        SettlementMath.Payouts memory p = SettlementMath.payouts(value, debt, rp, share);
        ok = p.avanaFee + p.keeperReward + p.borrowerSurplus == p.surplus && p.avanaFee <= p.surplus
            && p.borrowerSurplus == (p.surplus > p.oracleGain ? p.surplus - p.oracleGain : 0);
        uint256 outflow = debt + p.avanaFee + p.borrowerSurplus;
        uint256 inflow = callerFunds + rp;
        if (ok && inflow >= outflow) {
            uint256 out = SettlementMath.keeperPayout(callerFunds, rp, debt, p.avanaFee, p.borrowerSurplus);
            ok = inflow == outflow + out;
        }
    }

    /// @dev The waterfall reads the oracle value only through the oracle gain `G = max(0, value − debt)`. Above the
    /// debt the value is `debt + gain` with a gain below `2^128`, so the solver sees `G` as the gain itself; at or
    /// below it `G = 0` and every such value behaves alike, here `gain & debt`.
    function _checkWaterfall(
        uint256 gain,
        uint256 debt,
        uint256 rp,
        uint256 share,
        uint256 callerFunds,
        bool aboveDebt
    ) internal {
        gain %= B128;
        debt %= B128;
        uint256 value = aboveDebt ? debt + gain : gain & debt;
        assert(_waterfallHolds(value, debt, rp % B128, share, callerFunds % B128));
        ++checks;
    }

    function _slippageHolds(
        uint256 bonus,
        uint256 liquidationFee,
        uint256 allowance
    ) internal pure returns (bool) {
        uint256 bNet = SettlementMath.netBonus(bonus, liquidationFee);
        uint256 s = SettlementMath.effectiveSlippage(bNet, allowance);
        return bNet >= BPS && s <= allowance && s < BPS && (bNet > BPS ? bNet * (BPS - s) >= BPS * BPS : s == 0);
    }

    function _checkSlippage(
        uint256 bonus,
        uint256 liquidationFee,
        uint256 allowance
    ) internal {
        assert(_slippageHolds(bonus, liquidationFee, allowance));
        ++checks;
    }

    function _floorsHolds(
        uint256 value,
        uint256 s,
        uint256 units,
        uint256 allowance,
        uint256 legs
    ) internal pure returns (bool ok) {
        uint256 exact = (BPS - s) * value;
        uint256 gross = SettlementMath.recoveryFloor(value, s, 0, 0);
        uint256 minRec = SettlementMath.recoveryFloor(value, s, units, allowance);
        ok = BPS * gross >= exact && BPS * gross < exact + BPS;
        ok = ok && minRec <= gross && minRec + units + allowance >= gross;
        if (units + allowance != 0) ok = ok && BPS * minRec <= exact;
        uint256 minOut = SettlementMath.legMinOut(value, s, units, allowance, legs);
        ok = ok && minOut >= 1 && minOut >= minRec && minOut <= (value > 1 ? value : 1);
    }

    function _checkFloors(
        uint256 value,
        uint256 s,
        uint256 units,
        uint256 allowance,
        uint256 legs
    ) internal {
        value %= 2 ** 200;
        units %= B128;
        allowance %= B128;
        legs &= 3;
        if (legs == 0) _checkFloorFormulas(value, s, units, allowance, 1);
        else if (legs == 1) _checkFloorFormulas(value, s, units, allowance, 2);
        else if (legs == 2) _checkFloorFormulas(value, s, units, allowance, 3);
        else _checkFloorFormulas(value, s, units, allowance, 4);
        ++checks;
    }

    /// @dev The spec formulas: `gross = ⌈value × (10⁴ − s) / 10⁴⌉`, `minRec = gross − U − ε` floored at 0, and the
    /// leg minimum `max(1, gross − U − ⌊ε / legs⌋)` floored at 0 before the `max`.
    function _checkFloorFormulas(
        uint256 value,
        uint256 s,
        uint256 units,
        uint256 allowance,
        uint256 legs
    ) internal pure {
        uint256 gross = SettlementMath.recoveryFloor(value, s, 0, 0);
        uint256 minRec = SettlementMath.recoveryFloor(value, s, units, allowance);
        uint256 minOut = SettlementMath.legMinOut(value, s, units, allowance, legs);
        // value < 2^200 and 10⁴ − s ≤ 10⁴, so the product does not wrap. The ceiling is OpenZeppelin's, the one the
        // spec names, so the solver compares the same term.
        uint256 g;
        unchecked {
            g = Math.ceilDiv((BPS - s) * value, BPS);
        }
        assert(gross == g);
        assert(minRec == _subFloor(g, units, allowance));
        uint256 leg = _subFloor(g, units, allowance / legs);
        assert(minOut == (leg == 0 ? 1 : leg));
    }

    function _subFloor(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (uint256) {
        if (a <= b) return 0;
        a -= b;
        return a > c ? a - c : 0;
    }

    function _checkFlashBound(
        uint256 premium,
        uint256 amount,
        uint256 fee
    ) internal pure {
        bool within = SettlementMath.flashPremiumWithinCap(premium, amount, fee);
        // premium and amount are below 2^128 and the fee below 2^15, so no product wraps.
        unchecked {
            if (fee <= BPS) {
                assert(within == (premium <= fee * amount / BPS));
            } else {
                uint256 scaled = BPS * premium;
                assert(within == (scaled / fee + (scaled % fee > 0 ? 1 : 0) <= amount));
            }
        }
    }

    function _checkDeleverage(
        uint256 value,
        uint256 s,
        uint256 units,
        uint256 fee,
        uint256 debt
    ) internal pure {
        uint256 allowance = units / 3;
        uint256 cap = SettlementMath.deleverageCap(value, s, units, allowance, fee);
        // value < 2^200, so (10⁴ − s) × value and the floored Vnet times 10⁴ do not wrap.
        unchecked {
            uint256 vnet = _subFloor((BPS - s) * value / BPS, units, allowance);
            assert(cap == BPS * vnet / (BPS + fee));
            if (cap > 0) assert(SettlementMath.deleverageRepayment(debt, cap, 0) == (debt < cap ? debt : cap));
        }
    }

    function _deleverageHolds(
        uint256 value,
        uint256 s,
        uint256 units,
        uint256 maxFlashFeeBps,
        uint256 debt
    ) internal pure returns (bool ok) {
        uint256 allowance = units / 3;
        uint256 cap = SettlementMath.deleverageCap(value, s, units, allowance, maxFlashFeeBps);
        uint256 gross = (BPS - s) * value / BPS;
        uint256 vnet = gross > units + allowance ? gross - units - allowance : 0;
        ok = (BPS + maxFlashFeeBps) * cap <= BPS * vnet;
        if (ok && cap > 0) {
            uint256 x = SettlementMath.deleverageRepayment(debt, cap, 0);
            ok = x <= debt && x <= cap && x + maxFlashFeeBps * x / BPS <= vnet;
        }
    }
}
