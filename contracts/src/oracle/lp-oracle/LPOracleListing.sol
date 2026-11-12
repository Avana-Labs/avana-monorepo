// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAggregatorProxy} from "../../interfaces/external/chainlink/IAggregatorProxy.sol";
import {IOffchainAggregator} from "../../interfaces/external/chainlink/IOffchainAggregator.sol";
import {IMarketRegistryViews} from "../../policy/market-registry/IMarketRegistryViews.sol";
import {IParameterStoreViews} from "../../policy/parameter-store/IParameterStoreViews.sol";
import {OracleConfig} from "../../types/OracleConfig.sol";
import {OracleLeg} from "../../types/OracleLeg.sol";
import {OracleRoute} from "../../types/OracleRoute.sol";
import {SecondSource} from "../../types/SecondSource.sol";
import {SecondSourceKind} from "../../types/SecondSourceKind.sol";
import {TokenOracleConfig} from "../../types/TokenOracleConfig.sol";
import {LPOracleCalls} from "./LPOracleCalls.sol";
import {Evaluation, LPOracleCodes} from "./LPOracleTypes.sol";
import {LPOracleViews} from "./LPOracleViews.sol";
import {LPPriceMath} from "./LPPriceMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LPOracleListing
/// @notice `checkConfig`: the on-chain listing and configuration checks of `REQ-ORACLE-046` to `REQ-ORACLE-056` on a
/// candidate configuration, as a bitmap (0 = every check passes).
/// @dev Reads the configuration from calldata field by field (never decoded into memory). Uses the current answers of
/// the configured routes for the shock reference and the vault-token decimals, the pool's own token order and the
/// tokens' `decimals()`; the pricing module adds its own bits from `MODULE_CHECKS_SHIFT` up. A failed read fails the
/// check that needed it; the function never reverts except `InsufficientGas`.
/// @custom:spec REQ-ORACLE-046, REQ-ORACLE-047, REQ-ORACLE-048, REQ-ORACLE-049, REQ-ORACLE-050, REQ-ORACLE-051, REQ-ORACLE-053, REQ-ORACLE-054, REQ-ORACLE-056, REQ-ORACLE-077, REQ-ORACLE-100, Q-091, Q-184, Q-191, Q-321
abstract contract LPOracleListing is LPOracleViews {
    /// @dev ABI length of a `getMarket` return holding at most `MAX_POOL_TOKENS` tokens.
    uint256 private constant MARKET_LENGTH = 1248;

    /// @dev The bitmap of failed checks for `config`.
    /// @custom:spec REQ-ORACLE-046
    function _checkConfig(
        OracleConfig calldata config
    ) internal view returns (uint256 failed) {
        Layout storage $ = _s();
        uint256 n = $.tokens.length;
        if (config.tokens.length != n || config.marketId == 0 || config.marketId != $.marketId) {
            return LPOracleCodes.CHECK_TOKENS;
        }
        for (uint256 i = 0; i < n; ++i) {
            TokenOracleConfig calldata tc = config.tokens[i];
            if (tc.token != $.tokens[i]) failed |= LPOracleCodes.CHECK_TOKENS;
            (bool ok, uint8 dec) = _tokenDecimals($.tokens[i]);
            if (!ok || dec != $.tokenDecimals[i]) failed |= LPOracleCodes.CHECK_TOKEN_DECIMALS;
            failed |= _checkRoute(tc.routes[0]) | _checkRoute(tc.routes[1]);
        }
        failed |= _checkSharedFeeds(config) | _checkTolerances(config) | _checkBand(config);
        if (config.maxQuoteChangeBps == 0) failed |= LPOracleCodes.CHECK_QUOTE_CAP;
        if (_HAS_SEQUENCER != (config.sequencer.feed != address(0))) failed |= LPOracleCodes.CHECK_SEQUENCER;
        failed |= _checkAtCurrentQuotes(config) | _checkMarket(config.marketId);
    }

    // ─── Legs and routes (REQ-ORACLE-049, REQ-ORACLE-054) ───

    /// @dev Leg count, pinned decimals and bounds against the aggregator, heartbeat and ages, and the route's value
    /// range at its legs' pinned bounds.
    function _checkRoute(
        OracleRoute calldata rc
    ) private view returns (uint256 failed) {
        uint8 count = rc.legCount;
        if (count == 0 || count > 2) return LPOracleCodes.CHECK_ROUTE_RANGE;
        OracleLeg calldata a = rc.legs[0];
        failed = _checkLeg(a, count == 1);
        if (count == 1) {
            if (LPPriceMath.routeValue(a.maxAnswer, a.decimals) > LPPriceMath.MAX_ROUTE_ANSWER) {
                failed |= LPOracleCodes.CHECK_ROUTE_RANGE;
            }
            return failed;
        }
        OracleLeg calldata b = rc.legs[1];
        failed |= _checkLeg(b, true);
        if (
            uint256(a.decimals) + b.decimals < 8
                || LPPriceMath.routeValue(int256(a.minAnswer) + 1, a.decimals, int256(b.minAnswer) + 1, b.decimals) == 0
                || LPPriceMath.routeValue(a.maxAnswer, a.decimals, b.maxAnswer, b.decimals)
                    > LPPriceMath.MAX_ROUTE_ANSWER
        ) failed |= LPOracleCodes.CHECK_ROUTE_RANGE;
    }

    /// @dev One leg: decimals and bounds pinned from the aggregator (`minAnswer` positive, normalising to at least 1
    /// for a USD-quoted leg; `maxAnswer` at most the aggregator's), heartbeat in `(0, 86,400]`, margin in
    /// `(0, 3,600]`, liquidation age equal to `feedMaxAge` and borrow age in `(0, feedMaxAge]`.
    function _checkLeg(
        OracleLeg calldata leg,
        bool usdQuoted
    ) private view returns (uint256 failed) {
        address feed = leg.aggregator;
        bool ok = false;
        uint8 dec = 0;
        if (feed != address(0)) (ok, dec) = _feedDecimals(feed);
        if (!ok || dec != leg.decimals) failed |= LPOracleCodes.CHECK_LEG_DECIMALS;
        bool okBounds = false;
        int256 aggMin = 0;
        int256 aggMax = 0;
        if (feed != address(0)) (okBounds, aggMin, aggMax) = _bounds(feed);
        if (
            !okBounds || leg.minAnswer != aggMin || leg.minAnswer <= 0 || leg.maxAnswer > aggMax
                || leg.maxAnswer <= leg.minAnswer
                || (usdQuoted && LPPriceMath.normalizeAnswer(leg.minAnswer, leg.decimals) == 0)
        ) failed |= LPOracleCodes.CHECK_LEG_BOUNDS;
        uint256 maxAge = uint256(leg.heartbeat) + leg.heartbeatMargin;
        if (
            leg.heartbeat == 0 || leg.heartbeat > MAX_HEARTBEAT || leg.heartbeatMargin == 0
                || leg.heartbeatMargin > MAX_HEARTBEAT_MARGIN || leg.liquidationPriceMaxAge != maxAge
                || leg.borrowPriceMaxAge == 0 || leg.borrowPriceMaxAge > maxAge
        ) failed |= LPOracleCodes.CHECK_HEARTBEAT;
    }

    /// @dev `aggregator().minAnswer()` and `maxAnswer()` of a Chainlink proxy.
    function _bounds(
        address proxy
    ) private view returns (bool ok, int256 minAnswer, int256 maxAnswer) {
        bytes memory ret;
        (ok, ret) =
            LPOracleCalls.staticRead(proxy, CONFIG_CALL_GAS, abi.encodeCall(IAggregatorProxy.aggregator, ()), WORD);
        uint256 aggregator = 0;
        if (ok) (ok, aggregator) = LPOracleCalls.uintAt(ret, 0, type(uint160).max);
        if (!ok || aggregator == 0) return (false, 0, 0);
        // Bounded to 160 bits by the check above.
        // forge-lint: disable-next-line(unsafe-typecast)
        address agg = address(uint160(aggregator));
        (ok, ret) =
            LPOracleCalls.staticRead(agg, CONFIG_CALL_GAS, abi.encodeCall(IOffchainAggregator.minAnswer, ()), WORD);
        if (ok) (ok, minAnswer) = LPOracleCalls.intAt(ret, 0, 192);
        if (!ok) return (false, 0, 0);
        (ok, ret) =
            LPOracleCalls.staticRead(agg, CONFIG_CALL_GAS, abi.encodeCall(IOffchainAggregator.maxAnswer, ()), WORD);
        if (ok) (ok, maxAnswer) = LPOracleCalls.intAt(ret, 0, 192);
    }

    // ─── Independence (REQ-ORACLE-051) ───

    /// @dev No token's primary and alternate share an aggregator, no two tokens' alternates share one, and no
    /// oracle-network second source shares one with its token's routes.
    function _checkSharedFeeds(
        OracleConfig calldata config
    ) private pure returns (uint256) {
        uint256 n = config.tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            TokenOracleConfig calldata ti = config.tokens[i];
            if (_share(ti.routes[0], ti.routes[1])) return LPOracleCodes.CHECK_SHARED_FEED;
            SecondSource calldata s = ti.secondSource;
            if (
                s.kind == SecondSourceKind.OracleNetwork
                    && (_holds(ti.routes[0], s.source) || _holds(ti.routes[1], s.source))
            ) return LPOracleCodes.CHECK_SHARED_FEED;
            for (uint256 j = i + 1; j < n; ++j) {
                if (_share(ti.routes[1], config.tokens[j].routes[1])) return LPOracleCodes.CHECK_SHARED_FEED;
            }
        }
        return 0;
    }

    /// @dev Two routes share an aggregator.
    function _share(
        OracleRoute calldata x,
        OracleRoute calldata y
    ) private pure returns (bool) {
        uint256 count = x.legCount > 2 ? 2 : x.legCount;
        for (uint256 l = 0; l < count; ++l) {
            if (_holds(y, x.legs[l].aggregator)) return true;
        }
        return false;
    }

    /// @dev A route uses `feed`.
    function _holds(
        OracleRoute calldata route,
        address feed
    ) private pure returns (bool) {
        uint256 count = route.legCount > 2 ? 2 : route.legCount;
        for (uint256 l = 0; l < count; ++l) {
            if (route.legs[l].aggregator == feed) return true;
        }
        return false;
    }

    // ─── Tolerances and second sources (REQ-ORACLE-053, SPEC-ORC-020) ───

    /// @dev `T_i >= dev(primary legs) + dev(alternate legs) + feedAgreementMarginBps` and `S_i >= dev(primary legs) +
    /// own deviation + feedAgreementMarginBps`; each second source has a kind, a source and a window or age.
    function _checkTolerances(
        OracleConfig calldata config
    ) private view returns (uint256 failed) {
        (bool ok, bytes memory ret) = LPOracleCalls.staticRead(
            _s().parameterStore, CONFIG_CALL_GAS, abi.encodeCall(IParameterStoreViews.feedAgreementMarginBps, ()), WORD
        );
        uint256 margin = 0;
        if (ok) (ok, margin) = LPOracleCalls.uintAt(ret, 0, type(uint16).max);
        if (!ok) return LPOracleCodes.CHECK_TOLERANCE;
        uint256 n = config.tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            TokenOracleConfig calldata tc = config.tokens[i];
            uint256 primaryDev = _deviation(tc.routes[0]);
            if (tc.feedAgreementToleranceBps < primaryDev + _deviation(tc.routes[1]) + margin) {
                failed |= LPOracleCodes.CHECK_TOLERANCE;
            }
            (bool sourceOk, uint256 ownDev) = _secondSourceDeviation(tc.secondSource);
            if (!sourceOk) failed |= LPOracleCodes.CHECK_SECOND_SOURCE;
            else if (tc.secondSource.toleranceBps < primaryDev + ownDev + margin) failed |= LPOracleCodes.CHECK_TOLERANCE;
        }
    }

    /// @dev Sum of the published deviation thresholds of a route's legs.
    function _deviation(
        OracleRoute calldata route
    ) private pure returns (uint256 total) {
        uint256 count = route.legCount > 2 ? 2 : route.legCount;
        for (uint256 l = 0; l < count; ++l) {
            total += route.legs[l].feedDeviationThresholdBps;
        }
    }

    /// @dev A second source is well formed and its own deviation threshold: an oracle network's feed definition
    /// threshold, 0 for a pool TWAP (whose lag allowance the pricing module checks). A pool TWAP on the market's own
    /// pool is not independent of the market and is refused (`REQ-ORACLE-100`), whatever the ParameterStore's record
    /// says: the pool is the pricing module's, fixed at `initialize`.
    /// @custom:spec REQ-ORACLE-046, REQ-ORACLE-053, REQ-ORACLE-100
    function _secondSourceDeviation(
        SecondSource calldata s
    ) private view returns (bool ok, uint256 deviation) {
        if (s.source == address(0)) return (false, 0);
        if (s.kind == SecondSourceKind.PoolTwap) return (s.twapWindow != 0 && !_isOwnPool(s.poolRef), 0);
        if (s.kind != SecondSourceKind.OracleNetwork || s.maxAge == 0) return (false, 0);
        bytes memory ret;
        (ok, ret) = LPOracleCalls.staticRead(
            _s().parameterStore, CONFIG_CALL_GAS, abi.encodeCall(IParameterStoreViews.getFeed, (s.source)), 10 * WORD
        );
        uint256 dec = 0;
        if (ok) (ok, dec) = LPOracleCalls.uintAt(ret, 0, type(uint8).max);
        // FeedDef word 6 is feedDeviationThresholdBps.
        if (ok) (ok, deviation) = LPOracleCalls.uintAt(ret, 6 * WORD, type(uint16).max);
        return (ok && dec != 0, deviation);
    }

    // ─── Band (REQ-ORACLE-056) ───

    /// @dev Every token a USD stable: `usdBandLow < 10^8 < usdBandHigh`; otherwise exactly `0` and `type(uint256).max`.
    function _checkBand(
        OracleConfig calldata config
    ) private view returns (uint256) {
        Layout storage $ = _s();
        bool allStable = true;
        for (uint256 i = 0; i < $.isUsdStable.length; ++i) {
            if (!$.isUsdStable[i]) allStable = false;
        }
        bool ok = allStable
            ? config.usdBandLow < LPPriceMath.PRICE_UNIT && LPPriceMath.PRICE_UNIT < config.usdBandHigh
            : config.usdBandLow == 0 && config.usdBandHigh == type(uint256).max;
        return ok ? 0 : LPOracleCodes.CHECK_USD_BAND;
    }

    // ─── Current quotes: shock, vault-token decimals and the module (REQ-ORACLE-047, REQ-ORACLE-050) ───

    /// @dev Evaluates the configured routes at their current answers, then the listing shock, the vault-token decimals
    /// and the pricing module's checks.
    function _checkAtCurrentQuotes(
        OracleConfig calldata config
    ) private view returns (uint256 failed) {
        Evaluation memory e;
        _allocate(e);
        _loadSeed(e, config);
        if (!e.failed) _selectQuotes(e);
        if (e.failed) return LPOracleCodes.CHECK_QUOTES;
        (bool found, uint8 d) = LPPriceMath.vaultDecimals(_compositionOrEmpty, e.prices, _s().tokenDecimals);
        if (!found || d != _s().vaultDecimals) failed |= LPOracleCodes.CHECK_VAULT_DECIMALS;
        if (!_shockHolds(e.quotes)) failed |= LPOracleCodes.CHECK_SHOCK;
        failed |= _listingChecks(config, e.quotes) << LPOracleCodes.MODULE_CHECKS_SHIFT;
    }

    /// @dev With each token's quote multiplied by `LISTING_SHOCK_FACTOR` and the others divided by it, and the
    /// reverse, each shocked quote kept in `[1, MAX_ROUTE_ANSWER]` (the range `lpPrice` accepts), the composition is
    /// valid and `price8 >= 10^6` (`REQ-ORACLE-050`).
    function _shockHolds(
        uint256[] memory quotes
    ) private view returns (bool) {
        uint256 n = quotes.length;
        uint256[] memory shocked = new uint256[](n);
        for (uint256 j = 0; j < n; ++j) {
            for (uint256 up = 0; up < 2; ++up) {
                for (uint256 i = 0; i < n; ++i) {
                    bool raise = (i == j) == (up == 0);
                    uint256 q = raise
                        ? Math.min(quotes[i] * LISTING_SHOCK_FACTOR, LPPriceMath.MAX_ROUTE_ANSWER)
                        : Math.max(quotes[i] / LISTING_SHOCK_FACTOR, 1);
                    shocked[i] = LPPriceMath.valuationPrice(q, _s().isUsdStable[i]);
                }
                (bool ok, uint256 price8) = _price(shocked);
                if (!ok || price8 < MIN_SHOCKED_PRICE8) return false;
            }
        }
        return true;
    }

    /// @dev The pricing module's composition, or an empty array (which `lpPrice` rejects) for a failed read.
    function _compositionOrEmpty(
        uint256 units,
        uint256[] memory prices
    ) internal view returns (uint256[] memory amounts) {
        bool ok = false;
        (ok, amounts) = _composition(units, prices);
        if (!ok) amounts = new uint256[](0);
    }

    // ─── Registered market (REQ-ORACLE-047, REQ-ORACLE-048) ───

    /// @dev Once the MarketRegistry maps this feed to a market, that market must be `marketId`, with this feed, this
    /// integration, the vault-token decimals `d` and the tokens in this order. Before registration nothing is checked.
    function _checkMarket(
        uint256 marketId
    ) private view returns (uint256) {
        Layout storage $ = _s();
        (bool ok, bytes memory ret) = LPOracleCalls.staticRead(
            $.marketRegistry,
            CONFIG_CALL_GAS,
            abi.encodeCall(IMarketRegistryViews.marketOfLpOracle, (address(this))),
            WORD
        );
        uint256 registered = 0;
        if (ok) (ok, registered) = LPOracleCalls.wordAt(ret, 0);
        if (!ok) return LPOracleCodes.CHECK_MARKET;
        if (registered == 0) return 0;
        if (registered != marketId) return LPOracleCodes.CHECK_MARKET;
        (ok, ret) = LPOracleCalls.staticRead(
            $.marketRegistry,
            ORACLE_CONFIG_BASE_GAS,
            abi.encodeCall(IMarketRegistryViews.getMarket, (marketId)),
            MARKET_LENGTH
        );
        return ok && _marketMatches(ret) ? 0 : LPOracleCodes.CHECK_MARKET;
    }

    /// @dev Decodes the `Market` head words `integration` (4), `tokens` (10), `decimals` (13) and `lpOracle` (14).
    function _marketMatches(
        bytes memory ret
    ) private view returns (bool) {
        Layout storage $ = _s();
        (bool ok, uint256 head) = LPOracleCalls.uintAt(ret, 0, ret.length);
        uint256 integration = 0;
        uint256 dec = 0;
        uint256 oracle = 0;
        uint256 tokensAt = 0;
        if (ok) (ok, integration) = LPOracleCalls.wordAt(ret, head + 4 * WORD);
        if (ok) (ok, tokensAt) = LPOracleCalls.uintAt(ret, head + 10 * WORD, ret.length);
        if (ok) (ok, dec) = LPOracleCalls.wordAt(ret, head + 13 * WORD);
        if (ok) (ok, oracle) = LPOracleCalls.wordAt(ret, head + 14 * WORD);
        if (!ok || integration != uint160($.integration) || dec != $.vaultDecimals || oracle != uint160(address(this)))
        {
            return false;
        }
        uint256 n = $.tokens.length;
        uint256 count = 0;
        (ok, count) = LPOracleCalls.wordAt(ret, head + tokensAt);
        if (!ok || count != n) return false;
        for (uint256 i = 0; i < n; ++i) {
            uint256 token = 0;
            (ok, token) = LPOracleCalls.wordAt(ret, head + tokensAt + WORD * (i + 1));
            if (!ok || token != uint160($.tokens[i])) return false;
        }
        return true;
    }
}
