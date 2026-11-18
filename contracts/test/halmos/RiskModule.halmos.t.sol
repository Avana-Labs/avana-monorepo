// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskModuleDriftLogic} from "../../src/policy/risk-module/RiskModuleDriftLogic.sol";
import {RiskModuleMath} from "../../src/policy/risk-module/RiskModuleMath.sol";
import {RiskModuleImmutables} from "../../src/policy/risk-module/types/RiskModuleTypes.sol";
import {DriftReason} from "../../src/types/MarketTypes.sol";
import {RiskModuleMathHarness} from "../utils/harness/RiskModuleMathHarness.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The one MarketRegistry read the drift check makes first: the implementation status of a Spoke, set by the
/// check; every other read reverts, so a check that does not stop at the implementation reverts.
contract HalmosImplementationRegistry {
    address public implementation;
    bytes32 public codeHash;
    bool public current;

    function set(
        address i,
        bytes32 h,
        bool c
    ) external {
        (implementation, codeHash, current) = (i, h, c);
    }

    function spokeImplementationStatus(
        address
    ) external view returns (address, bytes32, bool) {
        return (implementation, codeHash, current);
    }
}

/// @title RiskModuleHalmosTest
/// @notice Symbolic checks of the RiskModule's formulas and decision steps, exactly the internal functions the pledge
/// and health checks run: the minimum pledge and the rescue rule (PROP-062), the rescue-excluded health factor and its
/// floor (PROP-067), and the stress-floor booking against the Hub `addCap` (PROP-030).
/// @dev The checks call `RiskModuleMath` through a harness or directly as internal library code, so the code verified
/// is the code `checkPledge` and `postHealthCheck` execute; where a product of two symbolic values made the solver
/// hang, a check proves that the code equals a reference formula and a Z3 model in `docs/spec/05-verification/z3/`
/// proves the formula's inequality (each such check names its model). The reads around them (accepted price, ParameterStore values, Spoke account data,
/// Collateralization rescue units) are symbolic inputs, as the PROP rows allow. Inputs are bounded to the listing
/// bounds (`L < 2^128`, `price8 < 2^64`, `d` 6 or 18, `minPledgeUsd <= 100,000e8`) so the nonlinear products stay
/// tractable; the fuzz twins in `test/fuzz/RiskModule.fuzz.t.sol` cover the full ranges. The implementation binding of
/// the drift check (PROP-078) runs the real `RiskModuleDriftLogic` against a registry whose implementation status is
/// symbolic.
contract RiskModuleHalmosTest is Test {
    RiskModuleMathHarness internal h;
    HalmosImplementationRegistry internal reg;
    RiskModuleDriftLogic internal drift;

    function setUp() public {
        h = new RiskModuleMathHarness();
        reg = new HalmosImplementationRegistry();
        drift = new RiskModuleDriftLogic(
            RiskModuleImmutables(
                address(reg), address(0x5701), address(0xC011), address(0xADA9), address(0x5A9), address(0x71E)
            )
        );
    }

    // PROP-078 verifies: REQ-ADAPTER-063, REQ-RISK-088, REQ-CONFIG-074
    /// @notice For every Spoke, implementation address and code hash the registry reports, an implementation that is
    /// not current makes the drift check report `SpokeImplementation` Spoke-wide (market 0), from both drift views,
    /// without reverting and before any other read; a current one never reports it from this step.
    function check_PROP_078_implementationNotCurrentIsDrift(
        address spoke,
        address impl,
        bytes32 codeHash,
        bool current,
        address proxy
    ) public {
        reg.set(impl, codeHash, current);
        uint256[] memory none = new uint256[](0);
        try drift.spokeDrift(spoke) returns (uint256 m, DriftReason r) {
            assert(!current);
            assert(m == 0 && r == DriftReason.SpokeImplementation);
        } catch {
            // Only a current implementation reaches the next read, which this registry does not serve.
            assert(current);
        }
        try drift.driftOf(spoke, none, proxy) returns (uint256 m, DriftReason r) {
            assert(!current);
            assert(m == 0 && r == DriftReason.SpokeImplementation);
        } catch {
            assert(current);
        }
    }

    /// @dev The pledge path from the minimum test to the exemption step: `true` when the pledge is admitted and whether
    /// as a rescue top-up.
    function _admit(
        uint256 value,
        uint256 minPledge,
        RiskModuleMath.Exemption memory x
    ) internal view returns (bool admitted, bool rescue) {
        if (value < h.rescueMinimum(minPledge)) return (false, false);
        x.belowMinimum = value < minPledge;
        RiskModuleMath.Outcome o = h.exemption(x);
        admitted = o == RiskModuleMath.Outcome.Pass || o == RiskModuleMath.Outcome.Rescue;
        rescue = o == RiskModuleMath.Outcome.Rescue;
    }

    // PROP-062 verifies: REQ-RISK-057, REQ-RISK-066, REQ-RISK-067, INV-069
    /// @notice With `pledgeUsd = mulDiv(L, price8, 10^18, Floor)`, an admitted pledge has `pledgeUsd >= required`, with
    /// `required = min(minPledgeUsd, 10e8)` for a rescue top-up and `minPledgeUsd` otherwise.
    function check_PROP_062_minimumPledge18(
        uint128 units,
        uint64 price8,
        uint64 minPledge,
        bool requireRescue,
        uint32 brk,
        bool eligible,
        uint64 charge,
        uint64 restore
    ) public view {
        vm.assume(price8 > 0 && minPledge <= 100_000e8);
        uint256 value = h.pledgeUsd(units, price8, 18);
        RiskModuleMath.Exemption memory x;
        (x.requireRescue, x.brk, x.eligible, x.charge, x.restore) = (requireRescue, brk, eligible, charge, restore);
        (bool admitted, bool rescue) = _admit(value, minPledge, x);
        uint256 rescueMin = minPledge < 10e8 ? minPledge : 10e8;
        if (admitted) assert(value >= (rescue ? rescueMin : minPledge));
        if (value < rescueMin) assert(!admitted);
    }

    // PROP-062 verifies: REQ-RISK-057, REQ-RISK-066, REQ-RISK-067, INV-069
    /// @notice The same with `d = 6` and the 5.2 example: `L = 5e18`, `price8 = 2e8`, `d = 18` gives exactly `10e8`.
    function check_PROP_062_minimumPledge6(
        uint128 units,
        uint64 price8,
        uint64 minPledge,
        bool requireRescue,
        uint32 brk,
        bool eligible,
        uint64 charge,
        uint64 restore
    ) public view {
        vm.assume(price8 > 0 && minPledge <= 100_000e8);
        uint256 value = h.pledgeUsd(units, price8, 6);
        RiskModuleMath.Exemption memory x;
        (x.requireRescue, x.brk, x.eligible, x.charge, x.restore) = (requireRescue, brk, eligible, charge, restore);
        (bool admitted, bool rescue) = _admit(value, minPledge, x);
        uint256 rescueMin = minPledge < 10e8 ? minPledge : 10e8;
        if (admitted) assert(value >= (rescue ? rescueMin : minPledge));
        assert(h.pledgeUsd(5e18, 2e8, 18) == 10e8);
        assert(h.pledgeUsd(4.99e18, 2e8, 18) == 998_000_000);
    }

    // PROP-067 verifies: REQ-RISK-068, SPEC-CF-005, INV-082
    /// @notice `hfEx` never exceeds `hf` and equals `hf` with no rescue units.
    function check_PROP_067_rescueExcludedBelowAave(
        uint64 hf,
        uint64 e,
        uint64 debtRay
    ) public view {
        vm.assume(debtRay > 0);
        uint256 hfEx = h.healthExcludingRescue(hf, e, debtRay);
        assert(hfEx <= hf);
        if (e == 0) assert(hfEx == hf);
    }

    // PROP-067 verifies: REQ-RISK-059, REQ-RISK-068, INV-082
    /// @notice `postHealthCheck` passes exactly when `hfEx >= max(1e18, minHealthFactor)`: the required level is that
    /// maximum. The two `requiredIsMaximum` checks split the inputs by which value is the larger (a tie goes to 1e18):
    /// `Wad` when `minHealthFactor` does not exceed 1e18, `MinHf` when it does. Every input falls in exactly one case, so
    /// together they cover every input below 2^256. This case: the required level is 1e18.
    /// @dev The check is linear (comparisons only); the split keeps each run to a few paths.
    function check_PROP_067_requiredIsMaximumWad(
        uint256 hfEx,
        uint256 minHf
    ) public pure {
        vm.assume(minHf <= 1e18);
        _requiredIsMaximum(hfEx, minHf, 1e18);
    }

    // PROP-067 verifies: REQ-RISK-059, REQ-RISK-068, INV-082
    /// @notice `check_PROP_067_requiredIsMaximumWad` when `minHealthFactor` exceeds 1e18: the required level is
    /// `minHealthFactor`.
    function check_PROP_067_requiredIsMaximumMinHf(
        uint256 hfEx,
        uint256 minHf
    ) public pure {
        vm.assume(minHf > 1e18);
        _requiredIsMaximum(hfEx, minHf, minHf);
    }

    /// @dev The required level equals `largest`, is at least both values, and a health factor that reaches it reaches
    /// both.
    function _requiredIsMaximum(
        uint256 hfEx,
        uint256 minHf,
        uint256 largest
    ) internal pure {
        uint256 required = RiskModuleMath.requiredHealthFactor(minHf);
        assert(required == largest);
        assert(required >= 1e18 && required >= minHf);
        if (hfEx >= required) assert(hfEx >= 1e18 && hfEx >= minHf);
    }

    // PROP-067 verifies: SPEC-CF-005, INV-082
    /// @notice The subtracted term rounds up: `hfEx > 0` implies `(hf - hfEx) * D >= E * WAD * RAY`, so `hfEx` never
    /// exceeds the exact rescue-excluded health factor. Values bounded to 64 bits for the solver; the fuzz twin
    /// `testFuzz_TEST_077_rescueExclusionNeverOverstates` covers the listing ranges.
    function check_PROP_067_rescueExclusionRoundsUp(
        uint64 hf,
        uint64 e,
        uint64 debtRay
    ) public view {
        vm.assume(debtRay > 0);
        uint256 hfEx = h.healthExcludingRescue(hf, e, debtRay);
        if (hfEx > 0) assert((uint256(hf) - hfEx) * debtRay >= uint256(e) * 1e45);
    }

    // PROP-067 verifies: SPEC-CF-005, INV-082
    /// @notice `E = mulDiv(u * p, CF * 1e18, 10^d * 1e4, Ceil)` rounds up, at the CF of the 2.7 example:
    /// `E * 1e10 >= u * p * 3120 * 1e18` for every `u, p < 2^40` (d = 6); the example gives `3.12e28` and
    /// `hfEx = 1.1688e18`.
    /// @dev Proved in two parts over the same inputs. This check: the code's `E` is 0 when `u` or `p` is 0, and otherwise
    /// equals `R = floor(q / 1e10) + (q mod 1e10 > 0 ? 1 : 0)` with `q = u * w`, `w = p * 3120 * 1e18`, the product the
    /// code forms. MATH-AR-92 (`docs/spec/05-verification/z3/aave-risk/ar17_halmos_references.py`) proves
    /// `R * 1e10 >= u * p * 3120 * 1e18`, and that no product here reaches `2^256 - 1`. Together they give the
    /// inequality this check asserted before the split, which made the solver compare two differently grouped
    /// products of symbolic values and ran out of its 5-hour budget (run 43492412351).
    function check_PROP_067_rescueValueRoundsUpFormula(
        uint40 units,
        uint40 price8
    ) public view {
        uint256 u = units;
        uint256 p = price8;
        if (u == 0 || p == 0) {
            assert(RiskModuleMath.rescueValue(u, p, 3120, 6) == 0);
        } else {
            uint256 w;
            // p < 2^40, so w < 2^112 (MATH-AR-92b).
            unchecked {
                w = p * 3120 * 1e18;
            }
            _assumeExactProduct(u, w);
            assert(RiskModuleMath.rescueValue(u, p, 3120, 6) == _ceilShape(u, w, 1e10));
        }
        assert(h.rescueValue(5e8, 2e8, 3120, 6) == 3.12e28);
        assert(h.healthExcludingRescue(1.2e18, 3.12e28, 1e57) == 1.1688e18);
    }

    // PROP-030 verifies: SPEC-CAP-006, INV-028
    /// @notice One pledge booked at `max(price8, stressFloorUsd)`, rounded up, carries at least `units * floor` of
    /// charge: `charge * 10^d >= units * stressFloorUsd` and `charge * 10^d >= units * price8`, for every
    /// `units < 2^40` and `price8, stressFloorUsd < 2^32` (d = 6). Summed over every pledge of a budget
    /// `regular + slice` this gives `units <= addCap * 10^d` for `addCap >= ceil((regular + slice) / stressFloorUsd)`;
    /// the fuzz twin `testFuzz_TEST_125_budgetFitsAddCap` checks the two-pledge sum.
    /// @dev Proved in two parts over the same inputs. This check: the code's charge equals
    /// `R = floor(q / 1e6) + (q mod 1e6 > 0 ? 1 : 0)` with `q = units * max(price8, stressFloorUsd)`. MATH-AR-90
    /// (`docs/spec/05-verification/z3/aave-risk/ar17_halmos_references.py`) proves `R * 1e6 >= units * stressFloorUsd`
    /// and `R * 1e6 >= units * price8`, and that `q < 2^256 - 1`. Together they give the two assertions this check made
    /// before the split; asserting them here made the solver compare two products of symbolic values, and the check ran
    /// out of its 5-hour budget (run 43492412351).
    function check_PROP_030_chargeCoversFloorFormula(
        uint40 units,
        uint32 price8,
        uint32 floorUsd
    ) public pure {
        uint256 u = units;
        uint256 a = price8;
        uint256 b = floorUsd;
        uint256 p = a > b ? a : b;
        _assumeExactProduct(u, p);
        assert(RiskModuleMath.usdCharge(u, a, b, 6) == _ceilShape(u, p, 1e6));
    }

    /// @dev Assumes `mulmod(x, y, 2^256 - 1) == x * y` (and `== y * x`). Every caller passes `x * y < 2^256 - 1` by its
    /// bit widths (MATH-AR-90b, MATH-AR-91d, MATH-AR-92b), where both sides are the exact product, so the assumption
    /// removes no input. It states, without a multiplication, the fact `Math.mulDiv` tests first: the high word of the
    /// 512-bit product is 0. The solver then rules out the 512-bit branch of `mulDiv` from this equality alone. Both
    /// operand orders are given because the optimizer may emit either order for the code's `x * y`.
    function _assumeExactProduct(
        uint256 x,
        uint256 y
    ) internal pure {
        unchecked {
            vm.assume(mulmod(x, y, type(uint256).max) == x * y);
            vm.assume(mulmod(x, y, type(uint256).max) == y * x);
        }
    }

    /// @dev `ceil(x * y / s)` in the shape `Math.mulDiv(x, y, s, Ceil)` computes it when the product fits 256 bits: the
    /// floor quotient, plus 1 when `mulmod` leaves a remainder. Called with `x * y < 2^256` and `s > 0`.
    function _ceilShape(
        uint256 x,
        uint256 y,
        uint256 s
    ) internal pure returns (uint256) {
        unchecked {
            return x * y / s + (mulmod(x, y, s) > 0 ? 1 : 0);
        }
    }
}
