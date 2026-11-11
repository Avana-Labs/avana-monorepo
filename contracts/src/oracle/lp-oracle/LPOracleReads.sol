// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAggregatorV3} from "../../interfaces/external/chainlink/IAggregatorV3.sol";
import {SecondSource} from "../../types/SecondSource.sol";
import {SecondSourceKind} from "../../types/SecondSourceKind.sol";
import {LPOracleCalls} from "./LPOracleCalls.sol";
import {LPOracleStorage} from "./LPOracleStorage.sol";
import {LPOracleCodes, LegEval, RouteEval, TokenEval} from "./LPOracleTypes.sol";
import {LPPriceMath} from "./LPPriceMath.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title LPOracleReads
/// @notice The external reads of an LPOracle evaluation other than its configuration and their decoding: the
/// aggregators' rounds and decimals, the tokens' decimals (listing only) and the oracle-network second sources
/// (`REQ-ORACLE-001`).
/// @dev Each read is a gas-guarded static call (`LPOracleCalls.staticRead`) whose return data is decoded word by word
/// with range checks, so a revert, a short or malformed return or an out-of-range value is a failed read and never a
/// revert of the view. Leg classes follow `REQ-ORACLE-002` and `REQ-ORACLE-003`: `Invalid` for any failed condition
/// other than age, `Stale` when only the age fails, `Error` when the read itself failed.
/// @custom:spec REQ-ORACLE-001, REQ-ORACLE-002, REQ-ORACLE-003, REQ-ORACLE-004, REQ-ORACLE-017, REQ-ORACLE-094, REQ-ORACLE-102, SPEC-ORC-002, SPEC-ORC-013, SPEC-ORC-019, SPEC-ORC-023
abstract contract LPOracleReads is LPOracleStorage {
    /// @dev ABI length of `latestRoundData()` / `getRoundData()` and of a one-word return.
    uint256 internal constant ROUND_LENGTH = 160;
    uint256 internal constant WORD = 32;

    // ─── Tokens ───

    /// @dev `decimals()` of `token`; false on a failed or malformed read.
    /// @custom:spec REQ-ORACLE-017
    function _tokenDecimals(
        address token
    ) internal view returns (bool ok, uint8 dec) {
        bytes memory ret;
        (ok, ret) = LPOracleCalls.staticRead(token, CONFIG_CALL_GAS, abi.encodeCall(IERC20Metadata.decimals, ()), WORD);
        uint256 value = 0;
        if (ok) (ok, value) = LPOracleCalls.uintAt(ret, 0, type(uint8).max);
        dec = SafeCast.toUint8(value);
    }

    // ─── Aggregators ───

    /// @dev `latestRoundData()` of `feed`: `ok` false on a failed or malformed read.
    /// @custom:spec REQ-ORACLE-001
    function _latestRound(
        address feed
    ) internal view returns (bool ok, uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt) {
        bytes memory ret;
        (ok, ret) = LPOracleCalls.staticRead(
            feed, FEED_CALL_GAS, abi.encodeCall(IAggregatorV3.latestRoundData, ()), ROUND_LENGTH
        );
        (ok, roundId, answer, startedAt, updatedAt) = _decodeRound(ok, ret);
    }

    /// @dev Decodes `(uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)`:
    /// at least 160 bytes, `roundId` and `answeredInRound` within 80 bits; anything else is a failed read.
    function _decodeRound(
        bool called,
        bytes memory ret
    ) internal pure returns (bool ok, uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt) {
        if (!called || ret.length < ROUND_LENGTH) return (false, 0, 0, 0, 0);
        uint256 id;
        uint256 rawAnswer;
        uint256 answeredInRound;
        // The five words of a length-checked buffer, read in place.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            id := mload(add(ret, 0x20))
            rawAnswer := mload(add(ret, 0x40))
            startedAt := mload(add(ret, 0x60))
            updatedAt := mload(add(ret, 0x80))
            answeredInRound := mload(add(ret, 0xa0))
        }
        if (id >> 80 != 0 || answeredInRound >> 80 != 0) return (false, 0, 0, 0, 0);
        // Bounded by the check above; the answer word is the ABI encoding of an int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        (ok, roundId, answer) = (true, uint80(id), int256(rawAnswer));
    }

    /// @dev `decimals()` of an aggregator: `ok` false on a failed or malformed read.
    /// @custom:spec REQ-ORACLE-001
    function _feedDecimals(
        address feed
    ) internal view returns (bool ok, uint8 dec) {
        bytes memory ret;
        (ok, ret) = LPOracleCalls.staticRead(feed, FEED_CALL_GAS, abi.encodeCall(IAggregatorV3.decimals, ()), WORD);
        uint256 value = 0;
        if (ok) (ok, value) = LPOracleCalls.uintAt(ret, 0, type(uint8).max);
        dec = SafeCast.toUint8(value);
    }

    /// @dev Reads and classifies one leg (`REQ-ORACLE-002`, `REQ-ORACLE-003`). `oneLeg` adds the normalised-answer
    /// condition of a one-leg route.
    /// @custom:spec REQ-ORACLE-001, REQ-ORACLE-002, REQ-ORACLE-003, SPEC-ORC-001, SPEC-ORC-019
    function _readLeg(
        LegEval memory leg,
        bool oneLeg
    ) internal view {
        bool ok = false;
        uint256 updatedAt = 0;
        (ok, leg.roundId, leg.answer,, updatedAt) = _latestRound(leg.feed);
        if (!ok) {
            leg.status = LPOracleCodes.ERROR;
            return;
        }
        leg.decoded = true;
        // A timestamp beyond uint64 is in the future and fails `updatedAt <= now` below.
        // forge-lint: disable-next-line(unsafe-typecast)
        leg.updatedAt = updatedAt > type(uint64).max ? type(uint64).max : uint64(updatedAt);
        (ok, leg.readDecimals) = _feedDecimals(leg.feed);
        if (!ok) {
            leg.status = LPOracleCodes.ERROR;
            return;
        }
        leg.status = _classify(leg, oneLeg);
    }

    /// @dev `Invalid` unless decimals match, `minAnswer < answer < maxAnswer`, `0 < updatedAt <= now` and (one-leg
    /// route) the normalised answer is at least 1; then `Stale` when `now - updatedAt > feedMaxAge`; else valid.
    function _classify(
        LegEval memory leg,
        bool oneLeg
    ) private view returns (uint8 status) {
        if (
            leg.readDecimals != leg.pinnedDecimals || leg.answer <= leg.minAnswer || leg.answer >= leg.maxAnswer
                || leg.updatedAt == 0 || leg.updatedAt > block.timestamp
                || (oneLeg && LPPriceMath.normalizeAnswer(leg.answer, leg.pinnedDecimals) == 0)
        ) return LPOracleCodes.INVALID;
        if (block.timestamp - leg.updatedAt > leg.maxAge) return LPOracleCodes.STALE;
        return LPOracleCodes.VALID;
    }

    /// @dev Reads every leg of `route` and sets its value, timestamp, class and `staleFrom` (`REQ-ORACLE-004`,
    /// `SPEC-ORC-002`, `SPEC-ORC-013`).
    /// @custom:spec REQ-ORACLE-004, SPEC-ORC-002, SPEC-ORC-013
    function _readRoute(
        RouteEval memory route
    ) internal view {
        bool oneLeg = route.legCount == 1;
        _readLeg(route.legs[0], oneLeg);
        if (!oneLeg) _readLeg(route.legs[1], false);
        LegEval memory a = route.legs[0];
        LegEval memory b = route.legs[1];
        bool readable = a.decoded && (oneLeg || b.decoded);
        if (readable) {
            route.value = oneLeg
                ? LPPriceMath.routeValue(a.answer, a.pinnedDecimals)
                : LPPriceMath.routeValue(a.answer, a.pinnedDecimals, b.answer, b.pinnedDecimals);
            route.updatedAt = oneLeg ? a.updatedAt : LPPriceMath.routeTimestamp(a.updatedAt, b.updatedAt);
        }
        route.status = _routeStatus(route, oneLeg);
    }

    /// @dev The route's class from its legs: `Error` if a leg is `Error`, else `Invalid` if a leg is `Invalid` or the
    /// value is the failing condition, else `Stale` if a leg is `Stale`, else valid.
    function _routeStatus(
        RouteEval memory route,
        bool oneLeg
    ) private pure returns (uint8) {
        uint8 sa = route.legs[0].status;
        uint8 sb = oneLeg ? LPOracleCodes.VALID : route.legs[1].status;
        if (sa == LPOracleCodes.ERROR || sb == LPOracleCodes.ERROR) return LPOracleCodes.ERROR;
        if (sa == LPOracleCodes.INVALID || sb == LPOracleCodes.INVALID || route.value == 0) {
            return LPOracleCodes.INVALID;
        }
        if (sa == LPOracleCodes.VALID && sb == LPOracleCodes.VALID) return LPOracleCodes.VALID;
        uint64 from = type(uint64).max;
        for (uint256 l = 0; l < route.legCount; ++l) {
            LegEval memory leg = route.legs[l];
            if (leg.status == LPOracleCodes.STALE) {
                uint256 end = uint256(leg.updatedAt) + leg.maxAge + 1;
                if (end < from) from = SafeCast.toUint64(end);
            }
        }
        route.staleFrom = from;
        return LPOracleCodes.STALE;
    }

    // ─── Second source ───

    /// @dev Value of token `t`'s oracle-network second source: valid under the leg rules with the source's own pinned
    /// decimals and bounds (its feed definition, read with the configuration) and `maxAge`; a source with no feed
    /// definition is unavailable; `PoolTwap` sources come from the pricing module.
    /// @custom:spec SPEC-ORC-020, REQ-ORACLE-100
    function _readSecondSource(
        TokenEval memory t,
        uint256 index,
        uint256[] memory quotes
    ) internal view {
        SecondSource memory src = t.second;
        if (src.kind == SecondSourceKind.PoolTwap) {
            (t.secondValid, t.secondValue) = _poolTwapPrice(index, src, quotes);
            return;
        }
        if (src.kind != SecondSourceKind.OracleNetwork || src.source == address(0) || t.secondDecimals == 0) return;
        LegEval memory leg;
        (leg.feed, leg.pinnedDecimals, leg.minAnswer, leg.maxAnswer) =
        (src.source, t.secondDecimals, t.secondMinAnswer, t.secondMaxAnswer);
        leg.maxAge = src.maxAge;
        _readLeg(leg, true);
        if (leg.status != LPOracleCodes.VALID) return;
        t.secondValid = true;
        t.secondValue = LPPriceMath.normalizeAnswer(leg.answer, leg.pinnedDecimals);
    }
}
