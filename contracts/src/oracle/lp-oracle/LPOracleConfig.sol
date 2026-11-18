// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAggregatorV3} from "../../interfaces/external/chainlink/IAggregatorV3.sol";
import {ISequencerUptimeFeed} from "../../interfaces/external/chainlink/ISequencerUptimeFeed.sol";
import {IParameterStore} from "../../policy/parameter-store/IParameterStore.sol";
import {OracleInputsLayout} from "../../policy/parameter-store/types/OracleInputsLayout.sol";
import {
    OracleConfig,
    OracleLeg,
    OracleRoute,
    SecondSource,
    SecondSourceKind,
    TokenOracleConfig
} from "../../types/OracleTypes.sol";
import {LPOracleCalls} from "./LPOracleCalls.sol";
import {LPOracleStorage} from "./LPOracleStorage.sol";
import {ConfigEval, Evaluation, LPOracleCodes, LegEval, RouteEval, TokenEval} from "./LPOracleTypes.sol";
import {LPPriceMath} from "./LPPriceMath.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title LPOracleConfig
/// @notice Loads the inputs of an evaluation: configuration, routes, sequencer and every leg's round.
/// @dev Every return word is range-checked, so a malformed return is a failed read, never a revert.
abstract contract LPOracleConfig is LPOracleStorage {
    /// @dev ABI length of `latestRoundData()` / `getRoundData()` and of a one-word return.
    uint256 internal constant ROUND_LENGTH = 160;
    uint256 internal constant WORD = 32;

    function _tokenDecimals(
        address token
    ) internal view returns (bool ok, uint8 dec) {
        bytes memory ret;
        (ok, ret) = LPOracleCalls.staticRead(token, CONFIG_CALL_GAS, abi.encodeCall(IERC20Metadata.decimals, ()), WORD);
        uint256 value = 0;
        if (ok) (ok, value) = LPOracleCalls.uintAt(ret, 0, type(uint8).max);
        dec = SafeCast.toUint8(value);
    }

    function _latestRound(
        address feed
    ) internal view returns (bool ok, uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt) {
        bytes memory ret;
        (ok, ret) = LPOracleCalls.staticRead(
            feed, FEED_CALL_GAS, abi.encodeCall(IAggregatorV3.latestRoundData, ()), ROUND_LENGTH
        );
        (ok, roundId, answer, startedAt, updatedAt) = _decodeRound(ok, ret);
    }

    /// @dev Decodes a `latestRoundData()` return; round ids beyond 80 bits are a failed read.
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

    function _feedDecimals(
        address feed
    ) internal view returns (bool ok, uint8 dec) {
        bytes memory ret;
        (ok, ret) = LPOracleCalls.staticRead(feed, FEED_CALL_GAS, abi.encodeCall(IAggregatorV3.decimals, ()), WORD);
        uint256 value = 0;
        if (ok) (ok, value) = LPOracleCalls.uintAt(ret, 0, type(uint8).max);
        dec = SafeCast.toUint8(value);
    }

    /// @dev Reads and classifies one leg. `oneLeg` adds the normalised-answer condition of a one-leg route.
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

    /// @dev `Invalid` if any condition but age fails; `Stale` if only age fails; else valid.
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

    /// @dev The route's class from its legs, worst first: `Error`, `Invalid` (or zero value), `Stale`, valid.
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

    /// @dev Token `t`'s second source: an oracle network under the leg rules, or a `PoolTwap` from the module.
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

    function _loadLive(
        Evaluation memory e,
        bool secondSources
    ) internal view {
        if (!_loadInputs(e, secondSources)) {
            _failRead(e);
            return;
        }
        _readSequencer(e);
        Layout storage $ = _s();
        uint256 n = e.tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            TokenEval memory t = e.tokens[i];
            if (t.version != $.routeVersion[i]) e.versionChanged = true;
            _readRoute(t.routes[0]);
            _readRoute(t.routes[1]);
        }
    }

    /// @dev Reads `getOracleInputs` into `e`; false on a failed or malformed read or another market.
    function _loadInputs(
        Evaluation memory e,
        bool secondSources
    ) internal view returns (bool ok) {
        Layout storage $ = _s();
        address[] memory list = $.tokens;
        uint256 n = list.length;
        uint256 stride = OracleInputsLayout.TOKEN_WORDS + (secondSources ? OracleInputsLayout.SECOND_WORDS : 0);
        uint256 count = OracleInputsLayout.HEAD_WORDS + n * stride;
        bytes memory ret;
        (ok, ret) = LPOracleCalls.staticRead(
            $.parameterStore,
            ORACLE_CONFIG_BASE_GAS + n * ORACLE_CONFIG_TOKEN_GAS,
            abi.encodeCall(IParameterStore.getOracleInputs, (address(this), list, secondSources)),
            WORD * (2 + count)
        );
        uint256[] memory w;
        if (ok) (ok, w) = LPOracleCalls.wordArray(ret, count);
        if (!ok || _at(w, 0) != $.marketId || !_setHead(e.cfg, w)) return false;
        for (uint256 i = 0; i < n; ++i) {
            uint256 k = OracleInputsLayout.HEAD_WORDS + i * stride;
            TokenEval memory t = e.tokens[i];
            if (!_setToken(t, w, k)) return false;
            // A malformed second source leaves the token unconfirmed; primary pricing goes on.
            if (secondSources) _setSecond(t, w, k + OracleInputsLayout.TOKEN_WORDS);
        }
        e.cfg.ok = true;
    }

    // Every field below is range-checked against its type before the cast; the casts cannot fail.
    // forge-lint: disable-start(unsafe-typecast)

    /// @dev Head words of `getOracleInputs`; false when a word exceeds its type.
    function _setHead(
        ConfigEval memory c,
        uint256[] memory w
    ) private pure returns (bool) {
        if (
            _at(w, 1) > type(uint32).max || _at(w, 2) > type(uint16).max || _at(w, 5) > type(uint32).max
                || _at(w, 6) > type(uint32).max || _at(w, 7) > type(uint32).max || _at(w, 8) > type(uint160).max
                || _at(w, 9) > type(uint32).max
        ) return false;
        c.marketId = _at(w, 0);
        c.twapWindow = uint32(_at(w, 1));
        c.consistencyToleranceBps = uint16(_at(w, 2));
        c.maxQuoteChangeBps = MAX_QUOTE_CHANGE_BPS;
        (c.usdBandLow, c.usdBandHigh) = (_at(w, 3), _at(w, 4));
        (c.cachedWindow, c.disagreementPauseMax, c.graceDuration) =
        (uint32(_at(w, 5)), uint32(_at(w, 6)), uint32(_at(w, 7)));
        (c.sequencerFeed, c.sequencerGracePeriod) = (address(uint160(_at(w, 8))), uint32(_at(w, 9)));
        return true;
    }

    /// @dev Token words from `k`; false for a word beyond its type, a route without 1 or 2 legs, or a bad leg.
    function _setToken(
        TokenEval memory t,
        uint256[] memory w,
        uint256 k
    ) private pure returns (bool) {
        if (_at(w, k) > type(uint16).max || _at(w, k + 1) > type(uint64).max || _at(w, k + 2) > 2) return false;
        (t.tolerance, t.version, t.replaced) = (uint16(_at(w, k)), uint64(_at(w, k + 1)), uint8(_at(w, k + 2)));
        for (uint256 r = 0; r < 2; ++r) {
            uint256 count = _at(w, k + 3 + r);
            if (count == 0 || count > 2) return false;
            RouteEval memory route = t.routes[r];
            route.legCount = uint8(count);
            for (uint256 l = 0; l < count; ++l) {
                if (!_setLeg(route.legs[l], w, k + 5 + (2 * r + l) * OracleInputsLayout.LEG_WORDS)) return false;
            }
        }
        return true;
    }

    function _setLeg(
        LegEval memory leg,
        uint256[] memory w,
        uint256 k
    ) private pure returns (bool ok) {
        uint256 feed;
        uint256 dec;
        uint256 lo;
        uint256 hi;
        uint256 heartbeat;
        uint256 margin;
        uint256 borrowAge;
        uint256 liquidationAge;
        // Loads the eight leg words and range-checks them in one pass.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            let p := add(w, shl(5, add(k, 1)))
            feed := mload(p)
            dec := mload(add(p, 0x20))
            lo := mload(add(p, 0x40))
            hi := mload(add(p, 0x60))
            heartbeat := mload(add(p, 0x80))
            margin := mload(add(p, 0xa0))
            borrowAge := mload(add(p, 0xc0))
            liquidationAge := mload(add(p, 0xe0))
            let bad := or(or(iszero(feed), shr(160, feed)), or(iszero(dec), shr(8, dec)))
            ok := iszero(or(bad, shr(32, or(or(heartbeat, margin), or(borrowAge, liquidationAge)))))
        }
        if (!ok) return false;
        (leg.feed, leg.pinnedDecimals) = (address(uint160(feed)), uint8(dec));
        (leg.minAnswer, leg.maxAnswer) = (int256(lo), int256(hi));
        leg.maxAge = LPPriceMath.feedMaxAge(uint32(heartbeat), uint32(margin));
        (leg.borrowAge, leg.liquidationAge) = (uint32(borrowAge), uint32(liquidationAge));
    }

    /// @dev The second source from `k`. A word beyond its type sets nothing, leaving the token unconfirmed.
    function _setSecond(
        TokenEval memory t,
        uint256[] memory w,
        uint256 k
    ) private pure {
        if (
            _at(w, k) > uint256(type(SecondSourceKind).max) || _at(w, k + 1) > type(uint160).max
                || _at(w, k + 3) > type(uint32).max || _at(w, k + 4) > type(uint32).max
                || _at(w, k + 5) > type(uint16).max || _at(w, k + 6) > type(uint8).max
        ) return;
        t.second = SecondSource({
            kind: SecondSourceKind(uint8(_at(w, k))),
            source: address(uint160(_at(w, k + 1))),
            poolRef: bytes32(_at(w, k + 2)),
            maxAge: uint32(_at(w, k + 3)),
            twapWindow: uint32(_at(w, k + 4)),
            toleranceBps: uint16(_at(w, k + 5))
        });
        (t.secondDecimals, t.secondMinAnswer, t.secondMaxAnswer) =
        (uint8(_at(w, k + 6)), int256(_at(w, k + 7)), int256(_at(w, k + 8)));
    }

    // forge-lint: disable-end(unsafe-typecast)

    function _at(
        uint256[] memory w,
        uint256 i
    ) private pure returns (uint256 value) {
        // The length was checked once against the layout; a per-index check would repeat it.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            value := mload(add(w, shl(5, add(i, 1))))
        }
    }

    function _loadSeed(
        Evaluation memory e,
        OracleConfig calldata config
    ) internal view {
        Layout storage $ = _s();
        uint256 n = e.tokens.length;
        if (config.tokens.length != n || config.marketId != $.marketId) {
            _failRead(e);
            return;
        }
        _seedHead(e.cfg, config);
        _readSequencer(e);
        for (uint256 i = 0; i < n; ++i) {
            TokenOracleConfig calldata tc = config.tokens[i];
            TokenEval memory t = e.tokens[i];
            (bool ok, uint8 dec) = _tokenDecimals($.tokens[i]);
            if (!ok || dec != $.tokenDecimals[i] || tc.token != $.tokens[i]) {
                _failRead(e);
                return;
            }
            t.tolerance = tc.feedAgreementToleranceBps;
            t.second = tc.secondSource;
            t.version = $.routeVersion[i];
            if (!_seedRoute(t.routes[0], tc.routes[0]) || !_seedRoute(t.routes[1], tc.routes[1])) {
                _failRead(e);
                return;
            }
            _readRoute(t.routes[0]);
            _readRoute(t.routes[1]);
        }
        e.decimalsCheckedAt = _now64();
    }

    function _seedHead(
        ConfigEval memory c,
        OracleConfig calldata config
    ) private pure {
        c.ok = true;
        c.marketId = config.marketId;
        c.twapWindow = config.twapWindow;
        c.consistencyToleranceBps = config.consistencyToleranceBps;
        c.maxQuoteChangeBps = config.maxQuoteChangeBps;
        c.usdBandLow = config.usdBandLow;
        c.usdBandHigh = config.usdBandHigh;
        c.cachedWindow = config.cachedWindow;
        c.disagreementPauseMax = config.disagreementPauseMax;
        c.graceDuration = config.graceDuration;
        c.sequencerFeed = config.sequencer.feed;
        c.sequencerGracePeriod = config.sequencer.gracePeriod;
    }

    /// @dev Copies one configured route; false for a route without 1 or 2 legs or a leg without feed or decimals.
    function _seedRoute(
        RouteEval memory route,
        OracleRoute calldata rc
    ) private pure returns (bool) {
        uint8 count = rc.legCount;
        if (count == 0 || count > 2) return false;
        route.legCount = count;
        for (uint256 l = 0; l < count; ++l) {
            OracleLeg calldata lc = rc.legs[l];
            LegEval memory leg = route.legs[l];
            if (lc.aggregator == address(0) || lc.decimals == 0) return false;
            leg.feed = lc.aggregator;
            leg.pinnedDecimals = lc.decimals;
            leg.minAnswer = lc.minAnswer;
            leg.maxAnswer = lc.maxAnswer;
            leg.maxAge = LPPriceMath.feedMaxAge(lc.heartbeat, lc.heartbeatMargin);
            leg.borrowAge = lc.borrowPriceMaxAge;
            leg.liquidationAge = lc.liquidationPriceMaxAge;
        }
        return true;
    }

    /// @dev Reads every token's `decimals()`; a failed read or changed value fails the market.
    function _verifyDecimals(
        Evaluation memory e
    ) internal view {
        Layout storage $ = _s();
        uint256 n = $.tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            (bool readable, uint8 dec) = _tokenDecimals($.tokens[i]);
            if (readable && dec == $.tokenDecimals[i]) continue;
            (e.decimalsMismatch, e.decimalsToken, e.decimalsRead, e.decimalsReadable) =
            (true, SafeCast.toUint8(i), dec, readable);
            e.decimalsCheckedAt = $.decimalsCheckedAt;
            _failRead(e);
            return;
        }
        e.decimalsCheckedAt = _now64();
    }

    /// @dev Reads the sequencer-uptime feed, if any; an answer other than exactly 160 bytes is unknown.
    function _readSequencer(
        Evaluation memory e
    ) internal view {
        address feed = e.cfg.sequencerFeed;
        bool readOk = false;
        int256 answer = 0;
        uint256 startedAt = 0;
        if (feed != address(0)) {
            bytes memory ret;
            (readOk, ret) = LPOracleCalls.staticRead(
                feed, FEED_CALL_GAS, abi.encodeCall(ISequencerUptimeFeed.latestRoundData, ()), ROUND_LENGTH + 1
            );
            (readOk,, answer, startedAt,) = _decodeRound(readOk && ret.length == ROUND_LENGTH, ret);
        }
        (e.seq.up, e.seq.down, e.seq.unknown, e.seq.inGrace, e.seq.ready) = LPPriceMath.sequencerStatus(
            feed != address(0), readOk, answer, startedAt, block.timestamp, e.cfg.sequencerGracePeriod
        );
        if (e.seq.up) e.seq.startedAt = SafeCast.toUint64(startedAt);
    }

    /// @dev A failed configuration, route, feed or decimals read: reason bit 1, market failed.
    function _failRead(
        Evaluation memory e
    ) internal pure {
        e.reasons |= LPOracleCodes.CONFIG_OR_DECIMALS_UNAVAILABLE;
        e.failed = true;
    }
}
