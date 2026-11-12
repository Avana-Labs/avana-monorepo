// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskModuleDriftLogic} from "../../src/policy/risk-module/RiskModuleDriftLogic.sol";
import {RiskModuleMath} from "../../src/policy/risk-module/RiskModuleMath.sol";
import {RiskModuleImmutables} from "../../src/policy/risk-module/types/RiskModuleImmutables.sol";
import {DriftReason} from "../../src/types/DriftReason.sol";
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
/// @dev The checks call `RiskModuleMath` through a harness, so the code verified is the code `checkPledge` and
/// `postHealthCheck` execute; the reads around them (accepted price, ParameterStore values, Spoke account data,
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
        bool capFail,
        bool eligible,
        uint64 charge,
        uint64 restore
    ) public view {
        vm.assume(price8 > 0 && minPledge <= 100_000e8);
        uint256 value = h.pledgeUsd(units, price8, 18);
        RiskModuleMath.Exemption memory x;
        (x.requireRescue, x.capFail, x.eligible, x.charge, x.restore) =
        (requireRescue, capFail, eligible, charge, restore);
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
    /// @notice `postHealthCheck` passes exactly when `hfEx >= max(1e18, hardHealthFloor, minHealthFactor)`: the required
    /// level is that maximum.
    function check_PROP_067_requiredIsMaximum(
        uint128 hfEx,
        uint128 hardFloor,
        uint128 minHf
    ) public pure {
        uint256 required = RiskModuleMath.requiredHealthFactor(hardFloor, minHf);
        assert(required >= 1e18 && required >= hardFloor && required >= minHf);
        if (hfEx >= required) assert(hfEx >= 1e18 && hfEx >= hardFloor && hfEx >= minHf);
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
    /// @notice `E = mulDiv(u * p, CF * 1e18, 10^d * 1e4, Ceil)` rounds up, at the CF of the 2.7 example; the example
    /// gives `3.12e28` and `hfEx = 1.1688e18`.
    function check_PROP_067_rescueValueRoundsUp(
        uint40 units,
        uint40 price8
    ) public view {
        uint256 e = h.rescueValue(units, price8, 3120, 6);
        assert(e * 1e10 >= uint256(units) * price8 * 3120 * 1e18);
        assert(h.rescueValue(5e8, 2e8, 3120, 6) == 3.12e28);
        assert(h.healthExcludingRescue(1.2e18, 3.12e28, 1e57) == 1.1688e18);
    }

    // PROP-030 verifies: SPEC-CAP-006, INV-028
    /// @notice One pledge booked at `max(price8, stressFloorUsd)`, rounded up, carries at least `units * floor` of
    /// charge: `charge * 10^d >= units * stressFloorUsd`. Summed over every pledge of a budget `regular + slice` this
    /// gives `units <= addCap * 10^d` for `addCap >= ceil((regular + slice) / stressFloorUsd)`; the fuzz twin
    /// `testFuzz_TEST_125_budgetFitsAddCap` checks the two-pledge sum.
    function check_PROP_030_chargeCoversFloor(
        uint40 units,
        uint32 price8,
        uint32 floorUsd
    ) public view {
        uint256 c = h.usdCharge(units, price8, floorUsd, 6);
        assert(c * 1e6 >= uint256(units) * floorUsd);
        assert(c * 1e6 >= uint256(units) * price8);
    }
}
