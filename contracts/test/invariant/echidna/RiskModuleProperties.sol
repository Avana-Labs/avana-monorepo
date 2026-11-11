// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskModuleMath} from "../../../src/policy/risk-module/RiskModuleMath.sol";

/// @title RiskModuleProperties
/// @notice Echidna and Medusa properties of the RiskModule's formulas (`RiskModuleMath`), in the units of 2.7: the
/// worked examples of SPEC-CAP-001, SPEC-CAP-003, SPEC-CF-001, SPEC-CF-005 and REQ-RISK-089 hold, and for every bounded
/// input the charge rounds up and the value down, the cap split keeps the regular part within its room, the rescue
/// exclusion never raises the health factor, the required level is the maximum of its three terms and the exemption
/// step admits a pledge below its minimum only as a rescue top-up.
/// @dev `property_` functions run in property mode; every other public function is an assertion entry point whose
/// inputs are reduced by `%` into the listing bounds, with no loop, so hevm can prove each one.
contract RiskModuleProperties {
    uint256 internal constant B64 = 2 ** 64;
    uint256 internal constant B120 = 2 ** 120;
    uint256 internal constant B128 = 2 ** 128;

    /// @notice Number of assertion calls made; written so each call is a transaction.
    uint256 public checks;

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

    /// @notice The charge rounds up and the minimum value down, both exactly, and the charge is at least the value.
    function charge(
        uint256 units,
        uint256 price8,
        uint256 floorUsd,
        bool d18
    ) public {
        units %= B120;
        price8 %= B64;
        floorUsd %= B64;
        uint8 d = d18 ? 18 : 6;
        uint256 scale = d18 ? 1e18 : 1e6;
        uint256 v = RiskModuleMath.pledgeUsd(units, price8, d);
        uint256 c = RiskModuleMath.usdCharge(units, price8, floorUsd, d);
        uint256 p = price8 > floorUsd ? price8 : floorUsd;
        assert(v * scale <= units * price8 && (v + 1) * scale > units * price8);
        assert(c * scale >= units * p);
        assert(c == 0 || (c - 1) * scale < units * p);
        assert(c >= v);
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

    /// @notice The rescue exclusion never raises the health factor and removes at least the exact value.
    function rescueExclusion(
        uint256 hf,
        uint256 e,
        uint256 debtRay
    ) public {
        hf %= B128;
        e %= B128;
        debtRay = 1 + (debtRay % B128);
        uint256 hfEx = RiskModuleMath.healthExcludingRescue(hf, e, debtRay);
        assert(hfEx <= hf);
        assert(hfEx == 0 || (hf - hfEx) * debtRay >= e * 1e45);
        ++checks;
    }

    /// @notice The required level is the maximum of 1.00, the hard floor and the caller's minimum.
    function required(
        uint256 hardFloor,
        uint256 minHf
    ) public {
        uint256 r = RiskModuleMath.requiredHealthFactor(hardFloor, minHf);
        assert(r >= 1e18 && r >= hardFloor && r >= minHf);
        assert(r == 1e18 || r == hardFloor || r == minHf);
        ++checks;
    }

    /// @notice A pledge needing an exemption passes only as a rescue top-up within its restore amount; the minimum
    /// alone gives `BelowMinimum`; `requireRescue` gives `NotRescue`.
    function exemption(
        bool requireRescue,
        bool capFail,
        bool depthUnavailable,
        uint32 brk,
        bool belowMinimum,
        bool eligible,
        uint256 chargeUsd,
        uint256 restore
    ) public {
        RiskModuleMath.Exemption memory x = RiskModuleMath.Exemption(
            requireRescue, depthUnavailable, capFail, brk, belowMinimum, eligible, chargeUsd, restore
        );
        RiskModuleMath.Outcome o = RiskModuleMath.exemption(x);
        bool needs = requireRescue || capFail || depthUnavailable || brk != 0 || belowMinimum;
        bool admit = eligible && chargeUsd <= restore;
        if (!needs) assert(o == RiskModuleMath.Outcome.Pass);
        if (needs && admit) assert(o == RiskModuleMath.Outcome.Rescue);
        if (needs && !admit && requireRescue) assert(o == RiskModuleMath.Outcome.NotRescue);
        if (needs && !admit && belowMinimum) {
            assert(o == RiskModuleMath.Outcome.BelowMinimum || o == RiskModuleMath.Outcome.NotRescue);
        }
        ++checks;
    }
}
