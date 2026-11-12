// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ISequencerUptimeFeed} from "../../interfaces/external/chainlink/ISequencerUptimeFeed.sol";
import {IParameterStoreViews} from "../../policy/parameter-store/IParameterStoreViews.sol";
import {OracleInputsLayout} from "../../policy/parameter-store/types/OracleInputsLayout.sol";
import {OracleConfig} from "../../types/OracleConfig.sol";
import {OracleLeg} from "../../types/OracleLeg.sol";
import {OracleRoute} from "../../types/OracleRoute.sol";
import {SecondSource} from "../../types/SecondSource.sol";
import {SecondSourceKind} from "../../types/SecondSourceKind.sol";
import {TokenOracleConfig} from "../../types/TokenOracleConfig.sol";
import {LPOracleCalls} from "./LPOracleCalls.sol";
import {LPOracleReads} from "./LPOracleReads.sol";
import {ConfigEval, Evaluation, LPOracleCodes, LegEval, RouteEval, TokenEval} from "./LPOracleTypes.sol";
import {LPPriceMath} from "./LPPriceMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title LPOracleConfig
/// @notice Loads the inputs of an evaluation: the configuration, every token's routes in force, route version and leg
/// settings and, when asked, its second source, all from one `ParameterStore.getOracleInputs(address(this), tokens,
/// withSecondSources)` read (live evaluation), or the same from the configuration passed to `initialize` and
/// `checkConfig` (seed evaluation); then the sequencer feed and every leg's round.
/// @dev The store resolves the routes in force and route versions from the MarketRegistry inside the same static call,
/// so a standby switch reaches the feed in the same block. The return data is read as the words of
/// `OracleInputsLayout`, each range-checked, so a malformed return is a failed read and never a decoder revert. A failed
/// read, another market, a route with no leg or more than two legs, or a leg with no feed definition fails the market
/// with reason bit 1 (`REQ-ORACLE-017`); an out-of-range second-source word only leaves that token unconfirmed
/// (`REQ-ORACLE-100`). Token decimals are the values stored at `initialize` (`REQ-ORACLE-058`); `poke()` re-reads them
/// (`REQ-ORACLE-107`) and every evaluation fails while the last `poke()` found one changed or unreadable. The
/// quote-change cap is the chain constant `MAX_QUOTE_CHANGE_BPS` (`REQ-ORACLE-103`).
/// @custom:spec REQ-ORACLE-017, REQ-ORACLE-083, REQ-ORACLE-094, REQ-ORACLE-095, REQ-ORACLE-099, REQ-ORACLE-100, REQ-ORACLE-107, SPEC-ORC-021, SPEC-ORC-023
abstract contract LPOracleConfig is LPOracleReads {
    // ─── Live evaluation ───

    /// @dev Loads the live inputs (with second sources when `secondSources`), the sequencer and every leg's round; a
    /// failed configuration read sets reason bit 1.
    /// @custom:spec REQ-ORACLE-017, REQ-ORACLE-094
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
    /// @custom:spec REQ-ORACLE-017, REQ-ORACLE-083, REQ-ORACLE-094
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
            abi.encodeCall(IParameterStoreViews.getOracleInputs, (address(this), list, secondSources)),
            WORD * (2 + count)
        );
        uint256[] memory w;
        if (ok) (ok, w) = LPOracleCalls.wordArray(ret, count);
        if (!ok || _at(w, 0) != $.marketId || !_setHead(e.cfg, w)) return false;
        for (uint256 i = 0; i < n; ++i) {
            uint256 k = OracleInputsLayout.HEAD_WORDS + i * stride;
            TokenEval memory t = e.tokens[i];
            if (!_setToken(t, w, k)) return false;
            // A second-source word beyond its type leaves the token's second source unset (`None`): the token is
            // unconfirmed and the primary pricing goes on (`REQ-ORACLE-100`).
            if (secondSources) _setSecond(t, w, k + OracleInputsLayout.TOKEN_WORDS);
        }
        e.cfg.ok = true;
    }

    // Every field below is range-checked against its type before the cast; the casts cannot fail.
    // forge-lint: disable-start(unsafe-typecast)

    /// @dev The head words: `marketId`, `twapWindow`, `consistencyToleranceBps`, the band, the three timers and the
    /// sequencer; false when a word exceeds its type.
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

    /// @dev Token words from `k`: tolerance, route version, replaced slot and both routes' legs; false for a word
    /// beyond its type, a route of 0 or more than 2 legs, or a leg with no aggregator or no feed definition.
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

    /// @dev One leg's words from `k`: aggregator, pinned decimals, bounds, heartbeat, margin and the two age limits.
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
        // The eight leg words in one pass, and one range check over them: the aggregator is non-zero and 160 bits,
        // the decimals non-zero and 8 bits, the heartbeat, margin and both age limits 32 bits.
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
        // Two's complement words of the signed bounds.
        (leg.minAnswer, leg.maxAnswer) = (int256(lo), int256(hi));
        leg.maxAge = LPPriceMath.feedMaxAge(uint32(heartbeat), uint32(margin));
        (leg.borrowAge, leg.liquidationAge) = (uint32(borrowAge), uint32(liquidationAge));
    }

    /// @dev The second source in force from `k`: kind, source, pool reference, maximum age, window, tolerance and the
    /// source's pinned decimals and bounds. A word beyond its type sets nothing, so the token's second source stays
    /// `None` and the token is unconfirmed (token bit 5); the ParameterStore's setters refuse such a configuration, and
    /// this check keeps the rule for any store implementation behind the proxy.
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

    /// @dev Word `i` of an array that `LPOracleCalls.wordArray` checked to hold every index the decoders above read.
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

    // ─── Seed evaluation (initialize and checkConfig) ───

    /// @dev Loads `config` as the configuration, its routes as the routes in force and its legs' pinned settings, and
    /// reads every leg; the stored route versions stand for the versions, so no version change is observed. Every
    /// token's `decimals()` is read and compared with the stored value, so the seed relies on a verification at `now`.
    /// The token-count and market check is defensive: `checkConfig` returns `CHECK_TOKENS` on the same condition
    /// before it reaches the seed, and `initialize` stores the tokens and market from the configuration it seeds, so no
    /// current path reaches it (recorded as unreachable in `security/coverage-thresholds.json`); it stays for any later
    /// initialization or upgrade flow that calls this function, and is reviewed whenever that flow changes.
    /// @custom:spec REQ-ORACLE-046, REQ-ORACLE-058, REQ-ORACLE-059
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

    /// @dev Copies the market-wide fields of `config`.
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

    /// @dev Copies one configured route's legs and pinned settings; false for a route of 0 or more than 2 legs or a
    /// leg with no aggregator or no pinned decimals.
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

    // ─── Token decimals (poke) ───

    /// @dev Reads every token's `decimals()` and compares it with the value stored at `initialize` (`REQ-ORACLE-107`).
    /// A verified evaluation relies on `now`; a failed read or a different value fails the market with reason bit 1 and
    /// records the first such token, what it read and whether it was readable. The stored decimals are never replaced.
    /// @custom:spec REQ-ORACLE-107, REQ-ORACLE-017
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

    // ─── Sequencer ───

    /// @dev Reads the chain's sequencer-uptime feed when the configuration names one (`SPEC-ORC-021`): an answer other
    /// than exactly 160 bytes is `sequencerUnknown` (the read copies at most 161 bytes, so a longer one is seen).
    /// @custom:spec SPEC-ORC-021, REQ-ORACLE-099
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
