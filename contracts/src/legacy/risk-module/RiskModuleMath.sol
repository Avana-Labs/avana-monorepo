// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleErrors} from "./IRiskModuleErrors.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RiskModuleMath
/// @notice The LegacyRiskModule's pure formulas: caps, restore amount, debt value and health factors.
/// @dev Every rounding is against the borrower.
library RiskModuleMath {
    /// @notice Static call with explicit gas, copying at most `maxLength` bytes of return data.
    /// @param maxLength Most bytes copied: the expected ABI length, plus one to see a longer answer.
    function staticRead(
        address target,
        uint256 callGas,
        bytes memory data,
        uint256 maxLength
    ) internal view returns (bool ok, bytes memory ret) {
        uint256 required = RiskModuleMath.gasFloor(callGas);
        // A probe that cannot receive its full gas reverts the whole call.
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (gasleft() < required) revert IRiskModuleErrors.InsufficientGas(gasleft(), required);
        ret = new bytes(maxLength);
        // A bounded static call: Solidity's own call syntax copies the whole return buffer.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            ok := staticcall(callGas, target, add(data, 0x20), mload(data), add(ret, 0x20), maxLength)
            let size := returndatasize()
            if gt(size, maxLength) { size := maxLength }
            mstore(ret, size)
        }
    }

    /// @notice Static call with explicit gas `callGas` whose answer must be exactly one 32-byte word.
    /// @dev Copies at most 32 bytes, into scratch space, and refuses a longer answer.
    /// @return ok The call did not revert and returned exactly 32 bytes.
    /// @return word The answer when `ok`, 0 otherwise.
    function staticReadWord(
        address target,
        uint256 callGas,
        bytes memory data
    ) internal view returns (bool ok, uint256 word) {
        uint256 required = RiskModuleMath.gasFloor(callGas);
        // A probe that cannot receive its full gas reverts the whole call.
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (gasleft() < required) revert IRiskModuleErrors.InsufficientGas(gasleft(), required);
        // Solidity's call syntax copies the whole return buffer, and its decoder accepts a longer one.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            let success := staticcall(callGas, target, add(data, 0x20), mload(data), 0x00, 0x20)
            ok := and(success, eq(returndatasize(), 0x20))
            // A short answer leaves scratch bytes unwritten; the word is read only when exactly 32 arrived.
            word := mul(ok, mload(0x00))
        }
    }

    /// @notice The 32-byte word at byte `offset` of `b`, bounds-checked.
    /// @return ok `offset + 32 <= b.length`.
    /// @return word The word (0 when out of bounds).
    function wordAt(
        bytes memory b,
        uint256 offset
    ) internal pure returns (bool ok, uint256 word) {
        if (offset > b.length || b.length - offset < 32) return (false, 0);
        // A bounds-checked read: abi.decode would revert on malformed data instead of reporting it.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            word := mload(add(add(b, 0x20), offset))
        }
        ok = true;
    }

    /// @notice Health factor below which an indebted account may make a rescue top-up, WAD; not a borrow gate.
    uint256 internal constant RESCUE_HEALTH_FACTOR = 1.1e18;

    /// @notice A rescue top-up must reach `min(minPledgeUsd, this)`, 8-decimal USD.
    uint256 internal constant RESCUE_MIN_PLEDGE_USD = 10e8;

    uint256 internal constant ISSUER_PROBE_GAS = 30_000;

    /// @notice Gas kept after a gas-limited external call returns, added to the pre-call gas check.
    uint256 internal constant POST_CALL_GAS = 5000;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 1e4;
    /// @dev `totalDebtValueRay / 1e45` is 8-decimal USD.
    uint256 internal constant DEBT_RAY_PER_USD8 = 1e45;

    /// @notice Outcome of the exemption step of a pledge.
    enum Outcome {
        Pass,
        // The pledge needs an exemption and is admitted as a rescue top-up.
        Rescue,
        // The minimum is the only exemption reason.
        BelowMinimum,
        NotRescue,
        Breaker
    }

    /// @notice Minimum-test value of a pledge, rounded down.
    function pledgeUsd(
        uint256 units,
        uint256 price8,
        uint8 d
    ) internal pure returns (uint256 usd) {
        usd = Math.mulDiv(units, price8, 10 ** uint256(d));
    }

    /// @notice Cap charge of a pledge at `max(price8, stressFloorUsd)`, rounded up.
    function usdCharge(
        uint256 units,
        uint256 price8,
        uint256 stressFloorUsd,
        uint8 d
    ) internal pure returns (uint256 usd) {
        uint256 p = price8 > stressFloorUsd ? price8 : stressFloorUsd;
        usd = Math.mulDiv(units, p, 10 ** uint256(d), Math.Rounding.Ceil);
    }

    /// @notice USD of collateral that restores `rescueHealthFactor`, rounded up; 0 when none is needed.
    /// @param hf Aave health factor before the pledge, WAD.
    function usdToRestore(
        uint256 hf,
        uint256 debtRay,
        uint256 cfBps
    ) internal pure returns (uint256 usd) {
        uint256 target = RiskModuleMath.RESCUE_HEALTH_FACTOR;
        if (cfBps == 0 || debtRay == 0 || hf >= target) return 0;
        uint256 x = Math.mulDiv(target - hf, debtRay, WAD * RAY, Math.Rounding.Ceil);
        usd = Math.mulDiv(x, BPS, cfBps * WAD, Math.Rounding.Ceil);
    }

    /// @notice Restore amount on the booking basis, rounded up; a served price of 0 is read as 1.
    function restoreBooked(
        uint256 restoreUsd,
        uint256 price8,
        uint256 stressFloorUsd,
        uint256 served8
    ) internal pure returns (uint256 usd) {
        uint256 p = price8 > stressFloorUsd ? price8 : stressFloorUsd;
        usd = Math.mulDiv(restoreUsd, p, served8 == 0 ? 1 : served8, Math.Rounding.Ceil);
    }

    /// @notice Split of a charge `c` between the regular room and the slice.
    /// @dev The caller tests the slice cap and the restore bound.
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
    function fits(
        uint256 used,
        uint256 add,
        uint256 cap
    ) internal pure returns (bool ok) {
        ok = used <= cap && add <= cap - used;
    }

    /// @notice Debt value, 8-decimal USD, rounded down.
    function debtUsd(
        uint256 debtRay
    ) internal pure returns (uint256 usd) {
        usd = debtRay / DEBT_RAY_PER_USD8;
    }

    /// @notice LP collateral factor: the weakest token's factor times `poolRiskFactor`, rounded down.
    function lpCollateralFactor(
        uint256 minTokenCfBps,
        uint256 poolRiskFactorBps
    ) internal pure returns (uint256 cfBps) {
        cfBps = (minTokenCfBps * poolRiskFactorBps) / BPS;
    }

    function bonusBoundViolated(
        uint256 maxLiquidationBonus,
        uint256 cfBps
    ) internal pure returns (bool violated) {
        violated = maxLiquidationBonus < BPS || Math.mulDiv(maxLiquidationBonus, cfBps, BPS, Math.Rounding.Ceil) >= BPS;
    }

    /// @notice Aave value of rescue units at the collateral factor, rounded up.
    /// @dev A price of `2^128` or more, or a factor above 1e4, saturates the value, which only lowers `hfEx`.
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

    /// @notice The price a borrow is held to: `min(fresh, accepted)`, or the accepted price when `fresh = 0`.
    function bookingPrice(
        uint256 accepted,
        uint256 fresh
    ) internal pure returns (uint256) {
        return fresh != 0 && fresh < accepted ? fresh : accepted;
    }

    /// @notice The price a pledge's cap charge is booked at: the fresh price, or the accepted price when there is none.
    function capPrice(
        uint256 accepted,
        uint256 fresh
    ) internal pure returns (uint256) {
        return fresh != 0 ? fresh : accepted;
    }

    /// @notice The health factor held to the booking price: `hf * min(served, accepted) / served`, rounded down.
    /// @dev Valid because the vault token is the account's only collateral.
    function boundedHealthFactor(
        uint256 hf,
        uint256 served,
        uint256 accepted
    ) internal pure returns (uint256) {
        if (served == 0 || accepted >= served) return hf;
        return Math.mulDiv(hf, accepted, served);
    }

    /// @notice `hfEx = hf - mulDiv(E, WAD * RAY, D, Ceil)`, saturating at 0; `hf` when `E = 0` or `D = 0`.
    function healthExcludingRescue(
        uint256 hf,
        uint256 e,
        uint256 debtRay
    ) internal pure returns (uint256 hfEx) {
        if (e == 0 || debtRay == 0) return hf;
        uint256 rescueHf;
        if (debtRay >= WAD * RAY) {
            // The quotient is at most `e`, so it fits.
            rescueHf = Math.mulDiv(e, WAD * RAY, debtRay, Math.Rounding.Ceil);
        } else {
            (bool ok, uint256 p) = Math.tryMul(e, WAD * RAY);
            if (!ok) return 0;
            rescueHf = Math.ceilDiv(p, debtRay);
        }
        hfEx = hf > rescueHf ? hf - rescueHf : 0;
    }

    function requiredHealthFactor(
        uint256 minHealthFactor
    ) internal pure returns (uint256 required) {
        required = minHealthFactor > WAD ? minHealthFactor : WAD;
    }

    /// @notice Gas floor before a probe with explicit gas `g`: `ceil(64 * g / 63) + POST_CALL_GAS`.
    function gasFloor(
        uint256 g
    ) internal pure returns (uint256 required) {
        required = Math.ceilDiv(64 * g, 63) + RiskModuleMath.POST_CALL_GAS;
    }

    function rescueMinimum(
        uint256 minPledgeUsd
    ) internal pure returns (uint256 usd) {
        uint256 cap = RiskModuleMath.RESCUE_MIN_PLEDGE_USD;
        usd = minPledgeUsd < cap ? minPledgeUsd : cap;
    }

    /// @notice Inputs of the exemption step of a pledge.
    struct Exemption {
        bool requireRescue;
        // The live market breaker reasons (`CONFIG_DRIFT` cleared for a top-up).
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

    /// @dev A pledge needing an exemption passes only as a rescue top-up (`eligible && charge <= restore`).
    function exemption(
        Exemption memory x
    ) internal pure returns (Outcome outcome) {
        bool gates = x.brk != 0;
        if (!x.requireRescue && !gates && !x.belowMinimum) return Outcome.Pass;
        if (x.eligible && x.charge <= x.restore) return Outcome.Rescue;
        if (x.belowMinimum && !x.requireRescue && !gates) return Outcome.BelowMinimum;
        if (x.requireRescue || x.belowMinimum) return Outcome.NotRescue;
        return Outcome.Breaker;
    }
}
