// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskModuleCalls} from "../../../src/policy/risk-module/RiskModuleCalls.sol";
import {RiskModuleMath} from "../../../src/policy/risk-module/RiskModuleMath.sol";

/// @title RiskModuleMathHarness
/// @notice External entry points over `RiskModuleMath` and `RiskModuleCalls` for the fuzz, Halmos and Echidna suites.
contract RiskModuleMathHarness {
    function pledgeUsd(
        uint256 units,
        uint256 price8,
        uint8 d
    ) external pure returns (uint256) {
        return RiskModuleMath.pledgeUsd(units, price8, d);
    }

    function usdCharge(
        uint256 units,
        uint256 price8,
        uint256 floorUsd,
        uint8 d
    ) external pure returns (uint256) {
        return RiskModuleMath.usdCharge(units, price8, floorUsd, d);
    }

    function usdToRestore(
        uint256 hf,
        uint256 debtRay,
        uint256 cfBps
    ) external pure returns (uint256) {
        return RiskModuleMath.usdToRestore(hf, debtRay, cfBps);
    }

    function restoreBooked(
        uint256 usd,
        uint256 price8,
        uint256 floorUsd,
        uint256 served8
    ) external pure returns (uint256) {
        return RiskModuleMath.restoreBooked(usd, price8, floorUsd, served8);
    }

    function split(
        uint256 c,
        uint256 regularUsed,
        uint256 marketCap,
        bool eligible
    ) external pure returns (uint256 sliceUsd, bool marketOk) {
        return RiskModuleMath.split(c, regularUsed, marketCap, eligible);
    }

    function poolShareExceeds(
        uint256 units,
        uint256 capBps,
        uint256 depth
    ) external pure returns (bool) {
        return RiskModuleMath.poolShareExceeds(units, capBps, depth);
    }

    function atOrBelowPeg(
        uint256[] memory quotes
    ) external pure returns (bool) {
        return RiskModuleMath.atOrBelowPeg(quotes);
    }

    function rescueValue(
        uint256 units,
        uint256 price8,
        uint256 cfBps,
        uint8 d
    ) external pure returns (uint256) {
        return RiskModuleMath.rescueValue(units, price8, cfBps, d);
    }

    function healthExcludingRescue(
        uint256 hf,
        uint256 e,
        uint256 debtRay
    ) external pure returns (uint256) {
        return RiskModuleMath.healthExcludingRescue(hf, e, debtRay);
    }

    function requiredHealthFactor(
        uint256 hardFloor,
        uint256 minHf
    ) external pure returns (uint256) {
        return RiskModuleMath.requiredHealthFactor(hardFloor, minHf);
    }

    function exemption(
        RiskModuleMath.Exemption memory x
    ) external pure returns (RiskModuleMath.Outcome) {
        return RiskModuleMath.exemption(x);
    }

    function rescueMinimum(
        uint256 minPledgeUsd
    ) external pure returns (uint256) {
        return RiskModuleMath.rescueMinimum(minPledgeUsd);
    }

    function gasFloor(
        uint256 g
    ) external pure returns (uint256) {
        return RiskModuleMath.gasFloor(g);
    }

    function bonusBoundViolated(
        uint256 maxLb,
        uint256 cf,
        uint256 factor,
        uint256 minBonus
    ) external pure returns (bool) {
        return RiskModuleMath.bonusBoundViolated(maxLb, cf, factor, minBonus);
    }

    function boundedHealthFactor(
        uint256 hf,
        uint256 served,
        uint256 accepted
    ) external pure returns (uint256) {
        return RiskModuleMath.boundedHealthFactor(hf, served, accepted);
    }

    function bookingPrice(
        uint256 accepted,
        uint256 fresh
    ) external pure returns (uint256) {
        return RiskModuleMath.bookingPrice(accepted, fresh);
    }

    function probe(
        address target,
        uint256 callGas
    ) external view returns (bool ok, uint256 length) {
        bytes memory ret;
        (ok, ret) = RiskModuleCalls.staticRead(target, callGas, abi.encodeWithSignature("paused()"), 32);
        length = ret.length;
    }

    function probeWord(
        address target,
        uint256 callGas,
        bytes4 sel
    ) external view returns (bool ok, uint256 word) {
        (ok, word) = RiskModuleCalls.staticReadWord(target, callGas, abi.encodePacked(sel));
    }
}
