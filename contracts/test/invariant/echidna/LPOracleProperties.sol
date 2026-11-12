// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Evaluation} from "../../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {FeedDef} from "../../../src/policy/parameter-store/types/FeedDef.sol";
import {OracleConfig} from "../../../src/types/OracleConfig.sol";
import {OracleLeg} from "../../../src/types/OracleLeg.sol";
import {PriceState} from "../../../src/types/PriceState.sol";
import {RouteSlot} from "../../../src/types/RouteSlot.sol";
import {SecondSource} from "../../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../../src/types/SecondSourceKind.sol";
import {TokenOracleConfig} from "../../../src/types/TokenOracleConfig.sol";
import {LPOracleHarnessPokeLogic} from "../../utils/harness/LPOracleHarness.sol";
import {
    OracleFeedMock,
    OracleRegistryMock,
    OracleStoreMock,
    OracleTokenMock,
    ReadMode
} from "../../utils/mocks/LPOracleMocks.sol";

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

/// @title LPOracleProperties
/// @notice Echidna and Medusa properties of the LPOracle base (2.10) over `LPOracleHarness` and mocked feeds,
/// registry and store. Between transactions: `latestAnswer()` never reverts and is at least 1; a state other than
/// Live serves at most the accepted price, Expired serves 1 and Cached the accepted price; the accepted price stays
/// positive and its timestamp never decreases. Inside one transaction: `poke()` moves the stored disagreement start
/// only to `now` (new episode or route-version change) or to 0, never refreshes the accepted timestamp without a newer
/// round, and keeps the failure timer once set while the market stays failed.
/// @dev `property_` functions run in property mode; `publish`, `breakFeed`, `switchStandby` and `pokeAndCheck` run in
/// assertion mode, each selecting among concrete cases with `if` branches. Feeds publish at `block.timestamp`, so the
/// fuzzers' time jumps make them stale.
contract LPOracleProperties {
    OracleRegistryMock internal immutable REGISTRY;
    OracleStoreMock internal immutable STORE;
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
        REGISTRY = new OracleRegistryMock();
        STORE = new OracleStoreMock();
        STORE.setRegistry(REGISTRY);
        TOKEN_A = new OracleTokenMock(6);
        TOKEN_B = new OracleTokenMock(6);
        PA = _feed();
        AA = _feed();
        PB = _feed();
        AB = _feed();
        STANDBY = _feed();
        OracleFeedMock sa = _feed();
        OracleFeedMock sb = _feed();
        REGISTRY.setRoutes(address(TOKEN_A), _one(address(PA)), _one(address(AA)), RouteSlot.None);
        REGISTRY.setRoutes(address(TOKEN_B), _one(address(PB)), _one(address(AB)), RouteSlot.None);
        OracleConfig memory c;
        c.marketId = 1;
        c.twapWindow = 1800;
        c.maxQuoteChangeBps = 100;
        c.usdBandLow = 0.9e8;
        c.usdBandHigh = 1.02e8;
        c.cachedWindow = 3600;
        c.disagreementPauseMax = 3600;
        c.graceDuration = 1800;
        c.tokens = new TokenOracleConfig[](2);
        c.tokens[0] = _token(address(TOKEN_A), address(PA), address(AA), address(sa));
        c.tokens[1] = _token(address(TOKEN_B), address(PB), address(AB), address(sb));
        STORE.setConfig(c);
        ORACLE = new LPOracleEchidnaTarget();
        address[] memory list = new address[](2);
        (list[0], list[1]) = (address(TOKEN_A), address(TOKEN_B));
        uint256[] memory k = new uint256[](2);
        (k[0], k[1]) = (1e18, 1e18);
        ORACLE.seed(address(STORE), address(REGISTRY), list, k);
        (,, lastAcceptedAt) = ORACLE.timers();
    }

    function _feed() internal returns (OracleFeedMock f) {
        f = new OracleFeedMock(8, 1, 1e12);
        f.push(1e8, block.timestamp);
        FeedDef memory d;
        d.decimals = 8;
        d.minAnswer = 1;
        d.maxAnswer = 1e12;
        d.feedHeartbeat = 86_400;
        d.heartbeatMargin = 1800;
        d.feedMaxAge = 88_200;
        d.feedDeviationThresholdBps = 25;
        d.borrowPriceMaxAge = 88_200;
        d.liquidationPriceMaxAge = 88_200;
        STORE.setFeed(address(f), d);
    }

    function _token(
        address token,
        address primary,
        address alternate,
        address second
    ) internal pure returns (TokenOracleConfig memory t) {
        t.token = token;
        (t.routes[0].legCount, t.routes[0].legs[0]) = (1, _leg(primary));
        (t.routes[1].legCount, t.routes[1].legs[0]) = (1, _leg(alternate));
        t.feedAgreementToleranceBps = 150;
        t.secondSource = SecondSource(SecondSourceKind.OracleNetwork, second, bytes32(0), 88_200, 0, 100);
    }

    function _leg(
        address feed
    ) internal pure returns (OracleLeg memory) {
        return OracleLeg(feed, 8, 86_400, 1800, 25, 1, 1e12, 88_200, 88_200);
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
        REGISTRY.setRoutes(
            address(TOKEN_B), _one(primary), _one(address(AB)), toStandby ? RouteSlot.Primary : RouteSlot.None
        );
        REGISTRY.bumpVersion(address(TOKEN_B));
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
