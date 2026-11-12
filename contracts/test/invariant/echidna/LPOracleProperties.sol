// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Evaluation} from "../../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {OracleInputsLayout} from "../../../src/policy/parameter-store/types/OracleInputsLayout.sol";
import {PriceState} from "../../../src/types/PriceState.sol";
import {RouteSlot} from "../../../src/types/RouteSlot.sol";
import {SecondSource} from "../../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../../src/types/SecondSourceKind.sol";
import {LPOracleHarnessPokeLogic} from "../../utils/harness/LPOracleHarness.sol";
import {OracleFeedMock, OracleTokenMock, ReadMode} from "../../utils/mocks/LPOracleMocks.sol";

/// @notice The LPOracle base's evaluation and writing call in one contract with the harness module, for the fuzzers:
/// the full implementation with its two logic contracts exceeds the 49,152-byte initcode limit of one harness, so this
/// target seeds its storage directly (the listing path is covered by the unit suites) and exposes `poke` and the served
/// price without the proxy.
contract LPOracleEchidnaTarget is LPOracleHarnessPokeLogic {
    constructor() LPOracleHarnessPokeLogic(address(0x7173), 12, 556_588, 3_000_000, false) {}

    /// @notice Stores the market and seeds the accepted price from a Live evaluation.
    function seed(
        address store,
        address registry,
        address[] calldata tokenList,
        uint256[] calldata coefficients
    ) external {
        Layout storage $ = _s();
        ($.parameterStore, $.marketRegistry, $.marketId, $.vaultDecimals) = (store, registry, 1, 6);
        for (uint256 i = 0; i < tokenList.length; ++i) {
            $.tokens.push(tokenList[i]);
            $.tokenDecimals.push(6);
            $.isUsdStable.push(true);
        }
        _m().coefficients = coefficients;
        // The Live price of the seeded market at $1 per token (2 * (10^6 - 1) * 10^8 / 10^6), as `initialize` stores it.
        $.accepted.answer = 199_999_800;
        $.accepted.updatedAt = uint64(block.timestamp);
        $.accepted.prices.push(1e8);
        $.accepted.prices.push(1e8);
        $.lastCachedWindow = 3600;
    }

    function pokeNow() external returns (PriceState) {
        return _poke();
    }

    function served() external view returns (PriceState state, uint256 answer, uint256 accepted) {
        Evaluation memory e = _evaluate(true);
        return (e.state, e.served, uint256(_s().accepted.answer));
    }

    /// @notice The failure and disagreement timers and the accepted price's timestamp, read in one call.
    function timers() external view returns (uint64 failedSince, uint64 disagreeSince, uint64 acceptedAt) {
        Layout storage $ = _s();
        return ($.failedSince, $.disagreeSince, $.accepted.updatedAt);
    }
}

/// @notice The ParameterStore and MarketRegistry reads of the oracle's `poke` path in one contract: the routes in force
/// and route versions (`OracleRegistryMock.activePriceRoutes`, `priceRouteVersion`) and the evaluation inputs built
/// from them word for word as `OracleStoreMock.getOracleInputs` builds them (`OracleInputsLayout`). Every feed of the
/// harness has the same definition (`FEED_*` below, the values `_feed` gave the shared store mock). The shared mocks
/// also carry the listing, configuration-struct and misbehaviour paths the unit suites need; with them the harness's
/// initcode was 49,374 bytes, above the 49,152-byte limit (EIP-3860) Medusa enforces on the harness deployment.
contract LPOracleFuzzConfig {
    struct Routes {
        address[] primary;
        address[] alternate;
        RouteSlot replaced;
        uint64 version;
    }

    uint8 internal constant FEED_DECIMALS = 8;
    uint256 internal constant FEED_MIN = 1;
    uint256 internal constant FEED_MAX = 1e12;
    uint256 internal constant FEED_HEARTBEAT = 86_400;
    uint256 internal constant FEED_MARGIN = 1800;
    uint256 internal constant FEED_MAX_AGE = 88_200;

    uint256[10] internal head;
    uint16[] internal tolerances;
    SecondSource[] internal secondList;
    mapping(address token => Routes) internal routes;
    mapping(address feed => bool) public known;

    function setHead(
        uint256[10] calldata words
    ) external {
        head = words;
    }

    /// @notice Appends the next token's agreement tolerance and second source, in the order of the market's tokens.
    function addToken(
        uint16 toleranceBps,
        SecondSource calldata second
    ) external {
        tolerances.push(toleranceBps);
        secondList.push(second);
    }

    function setFeed(
        address feed
    ) external {
        known[feed] = true;
    }

    function setRoutes(
        address token,
        address[] calldata primary,
        address[] calldata alternate,
        RouteSlot replaced
    ) external {
        Routes storage r = routes[token];
        (r.primary, r.alternate, r.replaced) = (primary, alternate, replaced);
    }

    function bumpVersion(
        address token
    ) external {
        routes[token].version += 1;
    }

    function activePriceRoutes(
        address token
    ) external view returns (address[] memory, address[] memory, RouteSlot) {
        Routes storage r = routes[token];
        return (r.primary, r.alternate, r.replaced);
    }

    function priceRouteVersion(
        address token
    ) external view returns (uint64) {
        return routes[token].version;
    }

    function getOracleInputs(
        address,
        address[] calldata tokens,
        bool withSecondSources
    ) external view returns (uint256[] memory w) {
        uint256 stride = OracleInputsLayout.TOKEN_WORDS + (withSecondSources ? OracleInputsLayout.SECOND_WORDS : 0);
        w = new uint256[](OracleInputsLayout.HEAD_WORDS + tokens.length * stride);
        for (uint256 i = 0; i < 10; ++i) {
            w[i] = head[i];
        }
        for (uint256 i = 0; i < tokens.length; ++i) {
            uint256 k = OracleInputsLayout.HEAD_WORDS + i * stride;
            Routes storage r = routes[tokens[i]];
            w[k] = i < tolerances.length ? tolerances[i] : 0;
            (w[k + 1], w[k + 2]) = (r.version, uint8(r.replaced));
            (w[k + 3], w[k + 4]) = (r.primary.length, r.alternate.length);
            _legs(w, k + 5, r.primary);
            _legs(w, k + 5 + 2 * OracleInputsLayout.LEG_WORDS, r.alternate);
            if (withSecondSources && i < secondList.length) _second(w, k + OracleInputsLayout.TOKEN_WORDS, i);
        }
    }

    function _second(
        uint256[] memory w,
        uint256 k,
        uint256 i
    ) internal view {
        SecondSource memory s = secondList[i];
        (w[k], w[k + 1], w[k + 2]) = (uint8(s.kind), uint160(s.source), uint256(s.poolRef));
        (w[k + 3], w[k + 4], w[k + 5]) = (s.maxAge, s.twapWindow, s.toleranceBps);
        if (s.kind != SecondSourceKind.OracleNetwork || !known[s.source]) return;
        (w[k + 6], w[k + 7], w[k + 8]) = (FEED_DECIMALS, FEED_MIN, FEED_MAX);
    }

    function _legs(
        uint256[] memory w,
        uint256 k,
        address[] storage route
    ) internal view {
        if (route.length > 2) return;
        for (uint256 l = 0; l < route.length; ++l) {
            uint256 at = k + l * OracleInputsLayout.LEG_WORDS;
            address feed = route[l];
            w[at] = uint160(feed);
            if (!known[feed]) continue;
            (w[at + 1], w[at + 2], w[at + 3]) = (FEED_DECIMALS, FEED_MIN, FEED_MAX);
            (w[at + 4], w[at + 5]) = (FEED_HEARTBEAT, FEED_MARGIN);
            (w[at + 6], w[at + 7]) = (FEED_MAX_AGE, FEED_MAX_AGE);
        }
    }
}

/// @title LPOracleProperties
/// @notice Echidna and Medusa properties of the LPOracle base (2.10) over `LPOracleHarness`, mocked feeds and
/// `LPOracleFuzzConfig` as the registry and store. Between transactions: `latestAnswer()` never reverts and is at least 1; a state other than
/// Live serves at most the accepted price, Expired serves 1 and Cached the accepted price; the accepted price stays
/// positive and its timestamp never decreases. Inside one transaction: `poke()` moves the stored disagreement start
/// only to `now` (new episode or route-version change) or to 0, never refreshes the accepted timestamp without a newer
/// round, and keeps the failure timer once set while the market stays failed.
/// @dev `property_` functions run in property mode; `publish`, `breakFeed`, `switchStandby` and `pokeAndCheck` run in
/// assertion mode, each selecting among concrete cases with `if` branches. Feeds publish at `block.timestamp`, so the
/// fuzzers' time jumps make them stale.
contract LPOracleProperties {
    LPOracleFuzzConfig internal immutable CONFIG;
    OracleTokenMock internal immutable TOKEN_A;
    OracleTokenMock internal immutable TOKEN_B;
    OracleFeedMock internal immutable PA;
    OracleFeedMock internal immutable AA;
    OracleFeedMock internal immutable PB;
    OracleFeedMock internal immutable AB;
    OracleFeedMock internal immutable STANDBY;
    LPOracleEchidnaTarget internal immutable ORACLE;

    uint64 internal lastAcceptedAt;

    constructor() {
        CONFIG = new LPOracleFuzzConfig();
        TOKEN_A = new OracleTokenMock(6);
        TOKEN_B = new OracleTokenMock(6);
        PA = _feed();
        AA = _feed();
        PB = _feed();
        AB = _feed();
        STANDBY = _feed();
        OracleFeedMock sa = _feed();
        OracleFeedMock sb = _feed();
        CONFIG.setRoutes(address(TOKEN_A), _one(address(PA)), _one(address(AA)), RouteSlot.None);
        CONFIG.setRoutes(address(TOKEN_B), _one(address(PB)), _one(address(AB)), RouteSlot.None);
        // marketId, twapWindow, consistencyToleranceBps, usdBandLow, usdBandHigh, cachedWindow, disagreementPauseMax,
        // graceDuration, sequencer feed (none), sequencer grace period.
        CONFIG.setHead([uint256(1), 1800, 0, 0.9e8, 1.02e8, 3600, 3600, 1800, 0, 0]);
        CONFIG.addToken(150, SecondSource(SecondSourceKind.OracleNetwork, address(sa), bytes32(0), 88_200, 0, 100));
        CONFIG.addToken(150, SecondSource(SecondSourceKind.OracleNetwork, address(sb), bytes32(0), 88_200, 0, 100));
        ORACLE = new LPOracleEchidnaTarget();
        address[] memory list = new address[](2);
        (list[0], list[1]) = (address(TOKEN_A), address(TOKEN_B));
        uint256[] memory k = new uint256[](2);
        (k[0], k[1]) = (1e18, 1e18);
        ORACLE.seed(address(CONFIG), address(CONFIG), list, k);
        (,, lastAcceptedAt) = ORACLE.timers();
    }

    function _feed() internal returns (OracleFeedMock f) {
        f = new OracleFeedMock(8, 1, 1e12);
        f.push(1e8, block.timestamp);
        CONFIG.setFeed(address(f));
    }

    function _one(
        address a
    ) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _pick(
        uint8 which
    ) internal view returns (OracleFeedMock) {
        uint8 w = which % 5;
        if (w == 0) return PA;
        if (w == 1) return AA;
        if (w == 2) return PB;
        if (w == 3) return AB;
        return STANDBY;
    }

    // ─── Properties (between transactions) ───

    function property_latestAnswerAtLeastOne() external view returns (bool) {
        try ORACLE.served() returns (PriceState, uint256 answer, uint256) {
            return answer >= 1;
        } catch {
            return false;
        }
    }

    function property_servedByState() external view returns (bool) {
        (PriceState state, uint256 answer, uint256 accepted) = ORACLE.served();
        if (answer < 1 || accepted < 1) return false;
        if (state == PriceState.Expired) return answer == 1;
        if (state == PriceState.Cached) return answer == accepted;
        if (state == PriceState.Drifting) return answer <= accepted;
        return true;
    }

    function property_acceptedTimestampNeverDecreases() external view returns (bool) {
        (,, uint64 acceptedAt) = ORACLE.timers();
        return acceptedAt >= lastAcceptedAt;
    }

    // ─── Assertion entry points ───

    /// @notice Publishes a new round of a bounded answer (0.80 to 1.20, or 0 for a failed answer).
    function publish(
        uint8 which,
        uint32 cents,
        bool zero
    ) external {
        int256 answer = zero ? int256(0) : int256(uint256(80 + cents % 41)) * 1e6;
        _pick(which).push(answer, block.timestamp);
    }

    /// @notice Makes a feed's read revert or work again.
    function breakFeed(
        uint8 which,
        bool broken
    ) external {
        _pick(which).setMode(OracleFeedMock.latestRoundData.selector, broken ? ReadMode.Revert : ReadMode.Normal);
    }

    /// @notice A guardian switches token B's primary slot to the standby, or the switch is reverted.
    function switchStandby(
        bool toStandby
    ) external {
        address primary = toStandby ? address(STANDBY) : address(PB);
        CONFIG.setRoutes(
            address(TOKEN_B), _one(primary), _one(address(AB)), toStandby ? RouteSlot.Primary : RouteSlot.None
        );
        CONFIG.bumpVersion(address(TOKEN_B));
    }

    /// @notice `poke()` and its timer rules (`REQ-ORACLE-027`, `REQ-ORACLE-028`, `REQ-ORACLE-029`, `REQ-ORACLE-095`).
    function pokeAndCheck() external {
        (uint64 failedBefore, uint64 disagreeBefore, uint64 acceptedBefore) = ORACLE.timers();
        PriceState state = ORACLE.pokeNow();
        (uint64 failedAfter, uint64 disagreeAfter, uint64 acceptedAfter) = ORACLE.timers();
        assert(disagreeAfter == disagreeBefore || disagreeAfter == 0 || disagreeAfter == block.timestamp);
        assert(acceptedAfter >= acceptedBefore);
        if (acceptedAfter != acceptedBefore) assert(state == PriceState.Live);
        if (failedBefore != 0 && failedAfter != 0) assert(failedAfter == failedBefore);
        lastAcceptedAt = acceptedAfter;
    }
}
