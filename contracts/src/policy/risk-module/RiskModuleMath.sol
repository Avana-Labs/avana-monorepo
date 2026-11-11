// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskModuleConstants} from "./RiskModuleConstants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RiskModuleMath
/// @notice The RiskModule's formulas, one pure function each: the cap charge and minimum value (SPEC-CAP-001), the cap
/// split (SPEC-CAP-002), the restore amount (SPEC-CAP-003), the pool-share test (SPEC-CAP-005), the debt value
/// (SPEC-CAP-009), the LP collateral factor and bonus bound (SPEC-CF-001, SPEC-CF-002), the rescue-excluded health
/// factor (SPEC-CF-005), the peg product of the concentration gate (SPEC-BRK-002), the probe gas floor (REQ-RISK-089) and
/// the exemption outcome of a pledge (REQ-RISK-066).
/// @dev USD amounts are 8-decimal integers, health factors WAD, Aave values USD × 1e26 and debt values Aave value × RAY.
/// Every rounding is against the borrower: charges, restore amounts and the rescue exclusion round up, the minimum value
/// rounds down. The Halmos suite checks these functions symbolically.
/// @custom:spec SPEC-CAP-001, SPEC-CAP-002, SPEC-CAP-003, SPEC-CAP-005, SPEC-CAP-009, SPEC-CF-001, SPEC-CF-002, SPEC-CF-005, SPEC-BRK-002, REQ-RISK-066, REQ-RISK-067, REQ-RISK-089
library RiskModuleMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 1e4;
    /// @dev `totalDebtValueRay / 1e45` is 8-decimal USD (SPEC-CAP-009).
    uint256 internal constant DEBT_RAY_PER_USD8 = 1e45;
    /// @dev `1e8` per token of an `n`-token peg product: `10^{8n}`, `n <= 8`.
    uint256 internal constant PEG8 = 1e8;

    /// @notice Outcome of the exemption step of a pledge (REQ-RISK-066).
    enum Outcome {
        // The pledge needs no exemption.
        Pass,
        // The pledge needs an exemption and is admitted as a rescue top-up.
        Rescue,
        // `BelowMinPledge(pledgeUsd, minPledgeUsd)`: the minimum is the only exemption reason.
        BelowMinimum,
        // `NotRescueTopUp(hf, usdCharge, restoreBooked)`.
        NotRescue,
        // `PoolShareUnavailable`.
        PoolShareUnavailable,
        // `PoolShareExceeded`.
        PoolShareExceeded,
        // `BreakerTripped(marketId, reasons)`.
        Breaker
    }

    /// @notice SPEC-CAP-001 minimum-test value `mulDiv(L, price8, 10^d, Floor)`.
    /// @custom:spec SPEC-CAP-001, REQ-RISK-057, REQ-RISK-070
    function pledgeUsd(
        uint256 units,
        uint256 price8,
        uint8 d
    ) internal pure returns (uint256 usd) {
        usd = Math.mulDiv(units, price8, 10 ** uint256(d));
    }

    /// @notice SPEC-CAP-001 charge `mulDiv(L, max(price8, stressFloorUsd), 10^d, Ceil)`.
    /// @custom:spec SPEC-CAP-001, REQ-RISK-021, REQ-RISK-026
    function usdCharge(
        uint256 units,
        uint256 price8,
        uint256 stressFloorUsd,
        uint8 d
    ) internal pure returns (uint256 usd) {
        uint256 p = price8 > stressFloorUsd ? price8 : stressFloorUsd;
        usd = Math.mulDiv(units, p, 10 ** uint256(d), Math.Rounding.Ceil);
    }

    /// @notice SPEC-CAP-003 `usdToRestore`: 8-decimal USD of collateral at the oracle price that restores
    /// `rescueHealthFactor`; 0 with no debt, at or above the target, or with `CF_m = 0`.
    /// @param hf Aave health factor before the pledge, WAD.
    /// @param debtRay `totalDebtValueRay`.
    /// @param cfBps The reserve's collateral factor on its latest dynamic key, bps.
    /// @custom:spec SPEC-CAP-003
    function usdToRestore(
        uint256 hf,
        uint256 debtRay,
        uint256 cfBps
    ) internal pure returns (uint256 usd) {
        uint256 target = RiskModuleConstants.RESCUE_HEALTH_FACTOR;
        if (cfBps == 0 || debtRay == 0 || hf >= target) return 0;
        uint256 x = Math.mulDiv(target - hf, debtRay, WAD * RAY, Math.Rounding.Ceil);
        usd = Math.mulDiv(x, BPS, cfBps * WAD, Math.Rounding.Ceil);
    }

    /// @notice SPEC-CAP-003 restore amount on the booking basis `mulDiv(usdToRestore, max(price8, floor), served8,
    /// Ceil)`; a served price of 0 is read as 1, the LPOracle's minimum.
    /// @custom:spec SPEC-CAP-003, REQ-RISK-026
    function restoreBooked(
        uint256 restoreUsd,
        uint256 price8,
        uint256 stressFloorUsd,
        uint256 served8
    ) internal pure returns (uint256 usd) {
        uint256 p = price8 > stressFloorUsd ? price8 : stressFloorUsd;
        usd = Math.mulDiv(restoreUsd, p, served8 == 0 ? 1 : served8, Math.Rounding.Ceil);
    }

    /// @notice SPEC-CAP-002 split of a charge `c` between the regular room and the slice.
    /// @dev `room = K > R ? K - R : 0`. Not eligible: `sliceUsd = 0` and `marketOk = c <= room`. Eligible:
    /// `sliceUsd = c > room ? c - room : 0` and `marketOk = true`; the slice cap and the restore bound are tested by the
    /// caller.
    /// @custom:spec SPEC-CAP-002, REQ-RISK-022
    function split(
        uint256 c,
        uint256 regularUsed,
        uint256 marketCap,
        bool eligible
    ) internal pure returns (uint256 sliceUsd, bool marketOk) {
        uint256 room = marketCap > regularUsed ? marketCap - regularUsed : 0;
        if (!eligible) return (0, c <= room);
        sliceUsd = c > room ? c - room : 0;
        marketOk = true;
    }

    /// @notice `used + add <= cap` without overflow.
    /// @custom:spec SPEC-CAP-002
    function fits(
        uint256 used,
        uint256 add,
        uint256 cap
    ) internal pure returns (bool ok) {
        ok = used <= cap && add <= cap - used;
    }

    /// @notice SPEC-CAP-005 failure `units * 1e4 > capBps * depth`; a product that does not fit 256 bits fails.
    /// @custom:spec SPEC-CAP-005, SPEC-BRK-002
    function poolShareExceeds(
        uint256 units,
        uint256 capBps,
        uint256 depth
    ) internal pure returns (bool exceeds) {
        (bool okL, uint256 lhs) = Math.tryMul(units, BPS);
        (bool okR, uint256 rhs) = Math.tryMul(capBps, depth);
        if (!okL) return true;
        if (!okR) return false;
        exceeds = lhs > rhs;
    }

    /// @notice Units still admissible under SPEC-CAP-005: `floor(capBps * depth / 1e4) - units`, floored at 0.
    /// @custom:spec SPEC-CAP-005, REQ-RISK-031
    function poolShareRoom(
        uint256 units,
        uint256 capBps,
        uint256 depth
    ) internal pure returns (uint256 room) {
        uint256 max = Math.mulDiv(capBps, depth, BPS);
        room = max > units ? max - units : 0;
    }

    /// @notice SPEC-BRK-002 peg test `prod_i q_i <= 10^{8n}`, stopping once the product exceeds the bound, so it never
    /// overflows; a missing quote (0) anywhere makes the product 0, so the test holds.
    /// @custom:spec SPEC-BRK-002
    function atOrBelowPeg(
        uint256[] memory quotes
    ) internal pure returns (bool below) {
        uint256 n = quotes.length;
        for (uint256 i = 0; i < n; ++i) {
            if (quotes[i] == 0) return true;
        }
        uint256 bound = PEG8 ** n;
        uint256 acc = 1;
        for (uint256 i = 0; i < n; ++i) {
            uint256 q = quotes[i];
            if (q > bound / acc) return false;
            acc *= q;
        }
        below = true;
    }

    /// @notice SPEC-CAP-009 debt value `floor(totalDebtValueRay / 1e45)`, 8-decimal USD.
    /// @custom:spec SPEC-CAP-009
    function debtUsd(
        uint256 debtRay
    ) internal pure returns (uint256 usd) {
        usd = debtRay / DEBT_RAY_PER_USD8;
    }

    /// @notice SPEC-CF-001 `floor(min_i CF_i * poolRiskFactor / 1e4)`.
    /// @custom:spec SPEC-CF-001
    function lpCollateralFactor(
        uint256 minTokenCfBps,
        uint256 poolRiskFactorBps
    ) internal pure returns (uint256 cfBps) {
        cfBps = (minTokenCfBps * poolRiskFactorBps) / BPS;
    }

    /// @notice SPEC-CF-002 and REQ-RISK-069: `ceil(maxLB * CF / 1e4) >= 1e4`, or the Spoke's minimum bonus above par
    /// `(maxLB - 1e4) * liquidationBonusFactor / 1e4` (floor, bps) below `minBonusBps`, the ParameterStore's
    /// `minLiquidationBonus(spoke)`; a `maxLB` below 1e4 violates. Example: `maxLB = 10,500`, factor 1,000 gives 50 bps,
    /// below a 100 bps minimum.
    /// @custom:spec SPEC-CF-002, REQ-RISK-069
    function bonusBoundViolated(
        uint256 maxLiquidationBonus,
        uint256 cfBps,
        uint256 liquidationBonusFactor,
        uint256 minBonusBps
    ) internal pure returns (bool violated) {
        if (maxLiquidationBonus < BPS) return true;
        if (Math.mulDiv(maxLiquidationBonus, cfBps, BPS, Math.Rounding.Ceil) >= BPS) return true;
        violated = ((maxLiquidationBonus - BPS) * liquidationBonusFactor) / BPS < minBonusBps;
    }

    /// @notice SPEC-CF-005 value `E = mulDiv(u * p, CF * 1e18, 10^d * 1e4, Ceil)` of rescue units, Aave value.
    /// @dev Computed as `mulDiv(u, p * CF * 1e18, 10^d * 1e4, Ceil)`, the same exact quotient; a price of `2^128` or
    /// more saturates `E`, which only lowers `hfEx`.
    /// @custom:spec SPEC-CF-005
    function rescueValue(
        uint256 units,
        uint256 price8,
        uint256 cfBps,
        uint8 d
    ) internal pure returns (uint256 e) {
        if (units == 0 || price8 == 0 || cfBps == 0) return 0;
        if (price8 >= 2 ** 128 || cfBps > BPS) return type(uint256).max;
        e = Math.mulDiv(units, price8 * cfBps * WAD, 10 ** uint256(d) * BPS, Math.Rounding.Ceil);
    }

    /// @notice SPEC-CF-005 `hfEx = hf - mulDiv(E, WAD * RAY, D, Ceil)`, saturating at 0; `hf` when `E = 0` or `D = 0`.
    /// @custom:spec SPEC-CF-005, REQ-RISK-068
    function healthExcludingRescue(
        uint256 hf,
        uint256 e,
        uint256 debtRay
    ) internal pure returns (uint256 hfEx) {
        if (e == 0 || debtRay == 0) return hf;
        uint256 sub;
        if (debtRay >= WAD * RAY) {
            // The quotient is at most `e`, so it fits.
            sub = Math.mulDiv(e, WAD * RAY, debtRay, Math.Rounding.Ceil);
        } else {
            (bool ok, uint256 p) = Math.tryMul(e, WAD * RAY);
            if (!ok) return 0;
            sub = Math.ceilDiv(p, debtRay);
        }
        hfEx = hf > sub ? hf - sub : 0;
    }

    /// @notice `max(1e18, hardHealthFloor, minHealthFactor)` (REQ-RISK-059, REQ-RISK-068).
    /// @custom:spec REQ-RISK-059, REQ-RISK-068, SPEC-CF-005
    function requiredHealthFactor(
        uint256 hardHealthFloor,
        uint256 minHealthFactor
    ) internal pure returns (uint256 required) {
        required = WAD;
        if (hardHealthFloor > required) required = hardHealthFloor;
        if (minHealthFactor > required) required = minHealthFactor;
    }

    /// @notice REQ-RISK-089 gas floor before a probe with explicit gas `g`: `ceil(64 * g / 63) + POST_CALL_GAS`.
    /// @custom:spec REQ-RISK-089
    function gasFloor(
        uint256 g
    ) internal pure returns (uint256 required) {
        required = Math.ceilDiv(64 * g, 63) + RiskModuleConstants.POST_CALL_GAS;
    }

    /// @notice The minimum a pledge must reach when it needs an exemption: `min(minPledgeUsd, RESCUE_MIN_PLEDGE_USD)`.
    /// @custom:spec REQ-RISK-067
    function rescueMinimum(
        uint256 minPledgeUsd
    ) internal pure returns (uint256 usd) {
        uint256 cap = RiskModuleConstants.RESCUE_MIN_PLEDGE_USD;
        usd = minPledgeUsd < cap ? minPledgeUsd : cap;
    }

    /// @notice Inputs of the exemption step of a pledge (REQ-RISK-066).
    struct Exemption {
        // `requireRescue` from the Adapter (`Paused(General)` or a frozen depositor).
        bool requireRescue;
        // SPEC-CAP-005 cannot be evaluated: the pool's depth is unavailable.
        bool depthUnavailable;
        // SPEC-CAP-005 fails for this pledge.
        bool capFail;
        // The market breaker without `ORACLE`: live, recovering or latched.
        uint32 brk;
        // `pledgeUsd < minPledgeUsd`.
        bool belowMinimum;
        // `borrowCount > 0 && hf < rescueHealthFactor`.
        bool eligible;
        // The pledge's booked charge, 8-decimal USD.
        uint256 charge;
        // The restore amount on the booking basis, 8-decimal USD.
        uint256 restore;
    }

    /// @notice REQ-RISK-066 exemption step.
    /// @dev `needsExemption = requireRescue || capFail || depthUnavailable || brk != 0 || belowMinimum`. Not needed:
    /// `Pass`. Needed and `eligible && charge <= restore`: `Rescue`. Otherwise, in order: the minimum as the only reason
    /// gives `BelowMinimum`; `requireRescue` or the minimum among several reasons gives `NotRescue`; else the first
    /// failing gate: `PoolShareUnavailable`, `PoolShareExceeded`, `Breaker`. The rescue minimum is tested before this
    /// step (`rescueMinimum`).
    /// @custom:spec REQ-RISK-023, REQ-RISK-057, REQ-RISK-066, REQ-RISK-073, REQ-RISK-074
    function exemption(
        Exemption memory x
    ) internal pure returns (Outcome outcome) {
        bool gates = x.capFail || x.depthUnavailable || x.brk != 0;
        if (!x.requireRescue && !gates && !x.belowMinimum) return Outcome.Pass;
        if (x.eligible && x.charge <= x.restore) return Outcome.Rescue;
        if (x.belowMinimum && !x.requireRescue && !gates) return Outcome.BelowMinimum;
        if (x.requireRescue || x.belowMinimum) return Outcome.NotRescue;
        if (x.depthUnavailable) return Outcome.PoolShareUnavailable;
        if (x.capFail) return Outcome.PoolShareExceeded;
        return Outcome.Breaker;
    }
}
