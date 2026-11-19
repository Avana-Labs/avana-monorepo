// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskModuleMath} from "../../../src/legacy/risk-module/RiskModuleMath.sol";

/// @title RiskModuleProperties
/// @notice Echidna and Medusa properties of the LegacyRiskModule's formulas (`RiskModuleMath`), in the units of 2.7: the
/// worked examples of SPEC-CAP-001, SPEC-CAP-003, SPEC-CF-001, SPEC-CF-005 and REQ-RISK-089 hold, and for every bounded
/// input the charge rounds up and the value down, the cap split keeps the regular part within its room, the rescue
/// exclusion never raises the health factor, the required level is the maximum of its two terms and the exemption
/// step admits a pledge below its minimum only as a rescue top-up.
/// @dev `property_` functions run in property mode; every other public function but the `fuzz` ones is an assertion
/// entry point whose inputs are reduced by `%` into the listing bounds, with no loop, so hevm can prove each one. The
/// charge and the rescue exclusion multiply two inputs, which z3 does not decide when both are symbolic, so their
/// assertion entry points take one factor of every product and every divisor from a literal (the decimals and the debt
/// value per entry point, the other factor from a `which` selector) and assert the formula in the shape the code
/// computes it; the rounding bounds over the whole input range are
/// `property_` functions on the inputs the `fuzz` entry points record (Echidna's property mode and Medusa).
contract RiskModuleProperties {
    uint256 internal constant B64 = 2 ** 64;
    uint256 internal constant B96 = 2 ** 96;
    uint256 internal constant B100 = 2 ** 100;
    uint256 internal constant B120 = 2 ** 120;
    uint256 internal constant B128 = 2 ** 128;
    /// @dev `WAD × RAY`: the rescue exclusion's factor, and the debt value from which the code takes `mulDiv`.
    uint256 internal constant WAD_RAY = 1e45;

    /// @notice Number of assertion calls made; written so each call is a transaction.
    uint256 public checks;

    /// @notice Inputs of the last `fuzz` call of each formula, as the fuzzer gave them.
    uint256[4] internal _chargeIn;
    uint256[3] internal _rescueIn;

    // ─── Properties ───

    function property_chargeExampleHolds() external pure returns (bool) {
        return RiskModuleMath.usdCharge(5e10, 199_990_000, 1e8, 6) == 9_999_500_000_000
            && RiskModuleMath.usdCharge(5e10, 80_000_000, 1e8, 6) == 5_000_000_000_000
            && RiskModuleMath.pledgeUsd(5e6, 199_990_000, 6) == 999_950_000
            && RiskModuleMath.pledgeUsd(5_001_000, 199_990_000, 6) == 1_000_149_990;
    }

    function property_restoreExampleHolds() external pure returns (bool) {
        uint256 usd = RiskModuleMath.usdToRestore(1.02e18, 1e57, 3000);
        return usd == 266_666_666_667
            && RiskModuleMath.restoreBooked(usd, 80_000_000, 1e8, 80_000_000) == 333_333_333_334
            && RiskModuleMath.restoreBooked(usd, 198_950_000, 1e8, 154_800_000) == 342_721_791_560;
    }

    function property_rescueExclusionExampleHolds() external pure returns (bool) {
        uint256 e = RiskModuleMath.rescueValue(5e8, 2e8, 3120, 6);
        return e == 3.12e28 && RiskModuleMath.healthExcludingRescue(1.2e18, e, 1e57) == 1.1688e18;
    }

    function property_factorAndGasExamplesHold() external pure returns (bool) {
        return RiskModuleMath.lpCollateralFactor(7500, 4000) == 3000
            && RiskModuleMath.lpCollateralFactor(8500, 9500) == 8075 && RiskModuleMath.gasFloor(30_000) == 35_477
            && RiskModuleMath.debtUsd(2.808e57) == 2_808_000_000_000;
    }

    /// @notice The charge rounds up and the minimum value down, both exactly, and the charge is at least the value, for
    /// every amount below `2^120`, price and stress floor below `2^64` and 6 or 18 decimals.
    function property_chargeRounds() external view returns (bool) {
        uint256[4] memory x = _chargeIn;
        return _chargeHolds(x[0] % B120, x[1] % B64, x[2] % B64, x[3] % 2 == 1);
    }

    /// @notice The rescue exclusion never raises the health factor and removes at least the exact value, for every
    /// health factor and value below `2^128` and debt value in `[1, 2^128]`.
    function property_rescueExclusionBounded() external view returns (bool) {
        uint256[3] memory x = _rescueIn;
        return _rescueHolds(x[0] % B128, x[1] % B128, 1 + x[2] % B128);
    }

    // ─── Full-range inputs for the properties ───

    function fuzzCharge(
        uint256 units,
        uint256 price8,
        uint256 floorUsd,
        bool d18
    ) external {
        _chargeIn = [units, price8, floorUsd, d18 ? 1 : 0];
    }

    function fuzzRescueExclusion(
        uint256 hf,
        uint256 e,
        uint256 debtRay
    ) external {
        _rescueIn = [hf, e, debtRay];
    }

    // ─── Assertion entry points ───

    /// @notice The value is `⌊L × price8 / 10⁶⌋` and the charge `⌈L × max(price8, floor) / 10⁶⌉` of a 6-decimal
    /// token, for every amount `L` below `2^120`, at five (price, stress floor) pairs (`_checkChargePairs`).
    /// `property_chargeRounds` checks the rounding bounds and `charge ≥ value` at every price and both decimals.
    function charge6(
        uint256 units,
        uint8 which
    ) public {
        _checkChargePairs(units % B120, which, 6, 1e6);
        ++checks;
    }

    /// @notice `charge6` for an 18-decimal token (`10¹⁸`).
    function charge18(
        uint256 units,
        uint8 which
    ) public {
        _checkChargePairs(units % B120, which, 18, 1e18);
        ++checks;
    }

    /// @notice The same formulas of a 6-decimal token for every price and stress floor below `2^64`, at six amounts
    /// (`_checkChargeUnits`).
    function chargeAtPrice6(
        uint256 price8,
        uint256 floorUsd,
        uint8 which
    ) public {
        _checkChargeUnits(price8 % B64, floorUsd % B64, which, 6, 1e6);
        ++checks;
    }

    /// @notice `chargeAtPrice6` for an 18-decimal token.
    function chargeAtPrice18(
        uint256 price8,
        uint256 floorUsd,
        uint8 which
    ) public {
        _checkChargeUnits(price8 % B64, floorUsd % B64, which, 18, 1e18);
        ++checks;
    }

    /// @notice The slice is at most the charge; a pledge that is not eligible takes no slice and fits the room.
    function capSplit(
        uint256 c,
        uint256 regular,
        uint256 cap,
        bool eligible
    ) public {
        c %= B128;
        regular %= B128;
        cap %= B128;
        (uint256 slice, bool ok) = RiskModuleMath.split(c, regular, cap, eligible);
        uint256 room = cap > regular ? cap - regular : 0;
        assert(slice <= c);
        if (!eligible) assert(slice == 0 && ok == (c <= room));
        if (eligible) assert(ok && c - slice <= room);
        ++checks;
    }

    /// @notice `hfEx = max(0, hf − ⌈E × 10⁴⁵ / D⌉)` at the smallest debt value where the code takes `mulDiv`,
    /// `D = WAD × RAY = 10⁴⁵`, for every health factor below `2^128`, at five values `E` (`_rescueValue`). With `E`
    /// symbolic as well, hevm explored this entry point only partially (security-slow run 43708786168);
    /// `property_rescueExclusionBounded` checks `hfEx ≤ hf` and that the exclusion removes at least the exact value at
    /// every value and at debts up to `2^128`.
    function rescueExclusion(
        uint256 hf,
        uint8 which
    ) public {
        _checkRescueExclusion(hf % B128, _rescueValue(which), WAD_RAY);
        ++checks;
    }

    /// @notice The same formula at the worked example's debt value, `D = 10⁵⁷`.
    function rescueExclusionDebt57(
        uint256 hf,
        uint8 which
    ) public {
        _checkRescueExclusion(hf % B128, _rescueValue(which), 1e57);
        ++checks;
    }

    /// @notice The same formula below `WAD × RAY`, where the code multiplies `E × 10⁴⁵` with an overflow check and
    /// divides by `D`, for every health factor below `2^128` at five (E, D) pairs: (1, 1), the worked example's
    /// 3.12 × 10²⁸ at 10⁴⁴, (2^100, 10⁴⁵ − 1), (2^128 − 1, 1), whose product overflows and gives 0, and (0, 1).
    function rescueExclusionSmallDebt(
        uint256 hf,
        uint8 which
    ) public {
        hf %= B128;
        which %= 5;
        if (which == 0) _checkRescueExclusion(hf, 1, 1);
        else if (which == 1) _checkRescueExclusion(hf, 3.12e28, 1e44);
        else if (which == 2) _checkRescueExclusion(hf, B100, WAD_RAY - 1);
        else if (which == 3) _checkRescueExclusion(hf, B128 - 1, 1);
        else _checkRescueExclusion(hf, 0, 1);
        ++checks;
    }

    /// @notice The required level is the maximum of 1.00 and the caller's minimum.
    function required(
        uint256 minHf
    ) public {
        uint256 r = RiskModuleMath.requiredHealthFactor(minHf);
        assert(r >= 1e18 && r >= minHf);
        assert(r == 1e18 || r == minHf);
        ++checks;
    }

    /// @notice A pledge needing an exemption passes only as a rescue top-up within its restore amount; the minimum
    /// alone gives `BelowMinimum`; `requireRescue` gives `NotRescue`.
    function exemption(
        bool requireRescue,
        uint32 brk,
        bool belowMinimum,
        bool eligible,
        uint256 chargeUsd,
        uint256 restore
    ) public {
        RiskModuleMath.Exemption memory x =
            RiskModuleMath.Exemption(requireRescue, brk, belowMinimum, eligible, chargeUsd, restore);
        RiskModuleMath.Outcome o = RiskModuleMath.exemption(x);
        bool needs = requireRescue || brk != 0 || belowMinimum;
        bool admit = eligible && chargeUsd <= restore;
        if (!needs) assert(o == RiskModuleMath.Outcome.Pass);
        if (needs && admit) assert(o == RiskModuleMath.Outcome.Rescue);
        if (needs && !admit && requireRescue) assert(o == RiskModuleMath.Outcome.NotRescue);
        if (needs && !admit && belowMinimum) {
            assert(o == RiskModuleMath.Outcome.BelowMinimum || o == RiskModuleMath.Outcome.NotRescue);
        }
        ++checks;
    }

    // ─── Helpers ───

    /// @dev `_checkCharge` at five (price, stress floor) pairs, 8-decimal USD: the worked example's price above the
    /// floor (199,990,000 and 10⁸), the floor above the price (80,000,000 and 10⁸), equal (10⁸), both 0, and the
    /// largest price below `2^64` with no floor. Each branch passes its literals straight to `_checkCharge`.
    function _checkChargePairs(
        uint256 units,
        uint8 which,
        uint8 d,
        uint256 scale
    ) internal pure {
        which %= 5;
        if (which == 0) _checkCharge(units, 199_990_000, 1e8, d, scale);
        else if (which == 1) _checkCharge(units, 80_000_000, 1e8, d, scale);
        else if (which == 2) _checkCharge(units, 1e8, 1e8, d, scale);
        else if (which == 3) _checkCharge(units, 0, 0, d, scale);
        else _checkCharge(units, B64 - 1, 0, d, scale);
    }

    /// @dev `_checkCharge` at six amounts: 0, 1, the worked examples' 5 × 10⁶, 5,001,000 and 5 × 10¹⁰, and
    /// `2^120 − 1`.
    function _checkChargeUnits(
        uint256 price8,
        uint256 floorUsd,
        uint8 which,
        uint8 d,
        uint256 scale
    ) internal pure {
        which %= 6;
        if (which == 0) _checkCharge(0, price8, floorUsd, d, scale);
        else if (which == 1) _checkCharge(1, price8, floorUsd, d, scale);
        else if (which == 2) _checkCharge(5e6, price8, floorUsd, d, scale);
        else if (which == 3) _checkCharge(5_001_000, price8, floorUsd, d, scale);
        else if (which == 4) _checkCharge(5e10, price8, floorUsd, d, scale);
        else _checkCharge(B120 - 1, price8, floorUsd, d, scale);
    }

    /// @dev The SPEC-CAP-001 value and charge in the shape `Math.mulDiv` computes them when the product fits 256 bits:
    /// the floor quotient, and the floor quotient plus 1 when `mulmod` leaves a remainder. `scale` is `10^d`, passed
    /// as a literal so no exponent is computed here.
    function _checkCharge(
        uint256 units,
        uint256 price8,
        uint256 floorUsd,
        uint8 d,
        uint256 scale
    ) internal pure {
        uint256 v = RiskModuleMath.pledgeUsd(units, price8, d);
        uint256 c = RiskModuleMath.usdCharge(units, price8, floorUsd, d);
        uint256 p = price8 > floorUsd ? price8 : floorUsd;
        // units is below 2^120 and both prices below 2^64, so no product wraps.
        unchecked {
            assert(v == units * price8 / scale);
            assert(c == units * p / scale + (mulmod(units, p, scale) > 0 ? 1 : 0));
        }
    }

    /// @dev The value rounds down and the charge up, both exactly, and the charge is at least the value.
    function _chargeHolds(
        uint256 units,
        uint256 price8,
        uint256 floorUsd,
        bool d18
    ) internal pure returns (bool) {
        uint8 d = d18 ? 18 : 6;
        uint256 scale = d18 ? 1e18 : 1e6;
        uint256 v = RiskModuleMath.pledgeUsd(units, price8, d);
        uint256 c = RiskModuleMath.usdCharge(units, price8, floorUsd, d);
        uint256 p = price8 > floorUsd ? price8 : floorUsd;
        return v * scale <= units * price8 && (v + 1) * scale > units * price8 && c * scale >= units * p
            && (c == 0 || (c - 1) * scale < units * p) && c >= v;
    }

    /// @dev SPEC-CF-005 `hfEx = max(0, hf − ⌈E × 10⁴⁵ / D⌉)`, `hf` when `E = 0`, and 0 when `D < WAD × RAY` and
    /// `E × 10⁴⁵` overflows, in the shape the code computes it. Called with `E × 10⁴⁵` below `2^256` whenever
    /// `D ≥ WAD × RAY`.
    function _checkRescueExclusion(
        uint256 hf,
        uint256 e,
        uint256 debtRay
    ) internal pure {
        uint256 hfEx = RiskModuleMath.healthExcludingRescue(hf, e, debtRay);
        uint256 expected = hf;
        if (debtRay < WAD_RAY && e > type(uint256).max / WAD_RAY) {
            expected = 0;
        } else if (e != 0) {
            // E × 10⁴⁵ fits 256 bits here (the line above, and the callers' bound on E).
            unchecked {
                uint256 r = e * WAD_RAY / debtRay + (mulmod(e, WAD_RAY, debtRay) > 0 ? 1 : 0);
                expected = hf > r ? hf - r : 0;
            }
        }
        assert(hfEx == expected);
        assert(hfEx <= hf);
    }

    /// @dev Five values of the rescued collateral: 1, the worked example's 3.12 × 10²⁸, `2^64 − 1`, `10³¹ + 1` and
    /// `2^96 − 1`; each times `10⁴⁵` fits 256 bits, as `_checkRescueExclusion` requires when `D ≥ WAD × RAY`.
    function _rescueValue(
        uint8 which
    ) internal pure returns (uint256) {
        which %= 5;
        if (which == 0) return 1;
        if (which == 1) return 3.12e28;
        if (which == 2) return B64 - 1;
        if (which == 3) return 1e31 + 1;
        return B96 - 1;
    }

    /// @dev The rescue exclusion never raises the health factor and removes at least the exact value.
    function _rescueHolds(
        uint256 hf,
        uint256 e,
        uint256 debtRay
    ) internal pure returns (bool) {
        uint256 hfEx = RiskModuleMath.healthExcludingRescue(hf, e, debtRay);
        return hfEx <= hf && (hfEx == 0 || (hf - hfEx) * debtRay >= e * 1e45);
    }
}
