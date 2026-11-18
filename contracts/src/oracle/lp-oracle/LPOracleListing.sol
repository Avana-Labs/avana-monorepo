// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAggregatorProxy} from "../../interfaces/external/chainlink/IAggregatorProxy.sol";
import {IOffchainAggregator} from "../../interfaces/external/chainlink/IOffchainAggregator.sol";
import {IMarketRegistry} from "../../policy/market-registry/IMarketRegistry.sol";
import {IParameterStore} from "../../policy/parameter-store/IParameterStore.sol";
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
/// @notice `checkConfig`: the on-chain listing and configuration checks, as a bitmap (0 = every check passes).
abstract contract LPOracleListing is LPOracleViews {
    /// @dev ABI length of a `getMarket` return holding at most `MAX_POOL_TOKENS` tokens.
    uint256 private constant MARKET_LENGTH = 1248;

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
        (bool readOk, uint256 registered) = _registeredMarket();
        failed |= _checkPrices(config, readOk && registered != 0) | _checkMarket(config.marketId, readOk, registered);
    }

    /// @dev Leg count, each leg, and the route's value range at its legs' pinned bounds.
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

    /// @dev Decimals and bounds match the aggregator; heartbeat, margin and age limits are within bounds.
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

    /// @dev No route shares an aggregator with its token's other route, another token's alternate or its second source.
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

    /// @dev Each tolerance covers the feeds' published deviations plus `feedAgreementMarginBps`.
    function _checkTolerances(
        OracleConfig calldata config
    ) private view returns (uint256 failed) {
        (bool ok, bytes memory ret) = LPOracleCalls.staticRead(
            _s().parameterStore, CONFIG_CALL_GAS, abi.encodeCall(IParameterStore.feedAgreementMarginBps, ()), WORD
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

    function _deviation(
        OracleRoute calldata route
    ) private pure returns (uint256 total) {
        uint256 count = route.legCount > 2 ? 2 : route.legCount;
        for (uint256 l = 0; l < count; ++l) {
            total += route.legs[l].feedDeviationThresholdBps;
        }
    }

    /// @dev Whether a second source is well formed, and its deviation threshold; refuses a TWAP on the own pool.
    function _secondSourceDeviation(
        SecondSource calldata s
    ) private view returns (bool ok, uint256 deviation) {
        if (s.source == address(0)) return (false, 0);
        if (s.kind == SecondSourceKind.PoolTwap) return (s.twapWindow != 0 && !_isOwnPool(s.poolRef), 0);
        if (s.kind != SecondSourceKind.OracleNetwork || s.maxAge == 0) return (false, 0);
        bytes memory ret;
        (ok, ret) = LPOracleCalls.staticRead(
            _s().parameterStore, CONFIG_CALL_GAS, abi.encodeCall(IParameterStore.getFeed, (s.source)), 10 * WORD
        );
        uint256 dec = 0;
        if (ok) (ok, dec) = LPOracleCalls.uintAt(ret, 0, type(uint8).max);
        // FeedDef word 6 is feedDeviationThresholdBps.
        if (ok) (ok, deviation) = LPOracleCalls.uintAt(ret, 6 * WORD, type(uint16).max);
        return (ok && dec != 0, deviation);
    }

    /// @dev All-stable markets need `usdBandLow < 10^8 < usdBandHigh`; others need the band disabled.
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

    /// @dev After registration the checks run at the stored listing prices, so a later price move cannot block config.
    function _checkPrices(
        OracleConfig calldata config,
        bool registered
    ) private view returns (uint256 failed) {
        uint256[] memory listing = _listingPrices();
        (bool found, uint8 d) = LPPriceMath.vaultDecimals(_compositionOrEmpty, listing, _s().tokenDecimals);
        if (!found || d != _s().vaultDecimals) failed |= LPOracleCodes.CHECK_VAULT_DECIMALS;
        uint256[] memory quotes = listing;
        if (!registered) {
            Evaluation memory e;
            _allocate(e);
            _loadSeed(e, config);
            if (!e.failed) _selectQuotes(e);
            if (e.failed) return failed | LPOracleCodes.CHECK_QUOTES;
            quotes = e.quotes;
        }
        if (!_shockHolds(quotes)) failed |= LPOracleCodes.CHECK_SHOCK;
        failed |= _listingChecks(config, quotes) << LPOracleCodes.MODULE_CHECKS_SHIFT;
    }

    function _listingPrices() internal view returns (uint256[] memory prices) {
        uint128[] storage stored = _s().listingPrices;
        prices = new uint256[](stored.length);
        for (uint256 i = 0; i < stored.length; ++i) {
            prices[i] = stored[i];
        }
    }

    /// @dev The price stays valid and at least `MIN_SHOCKED_PRICE8` with each token shocked by `LISTING_SHOCK_FACTOR`.
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

    /// @dev The composition, or an empty array (which `lpPrice` rejects) for a failed read.
    function _compositionOrEmpty(
        uint256 units,
        uint256[] memory prices
    ) internal view returns (uint256[] memory amounts) {
        bool ok = false;
        (ok, amounts) = _composition(units, prices);
        if (!ok) amounts = new uint256[](0);
    }

    /// @dev The market this feed is registered for, 0 before registration.
    function _registeredMarket() private view returns (bool ok, uint256 registered) {
        bytes memory ret;
        (ok, ret) = LPOracleCalls.staticRead(
            _s().marketRegistry,
            CONFIG_CALL_GAS,
            abi.encodeCall(IMarketRegistry.marketOfLpOracle, (address(this))),
            WORD
        );
        if (ok) (ok, registered) = LPOracleCalls.wordAt(ret, 0);
    }

    /// @dev Once registered, the registry's market must match this feed; before registration nothing is checked.
    function _checkMarket(
        uint256 marketId,
        bool readOk,
        uint256 registered
    ) private view returns (uint256) {
        if (!readOk) return LPOracleCodes.CHECK_MARKET;
        if (registered == 0) return 0;
        if (registered != marketId) return LPOracleCodes.CHECK_MARKET;
        (bool ok, bytes memory ret) = LPOracleCalls.staticRead(
            _s().marketRegistry,
            ORACLE_CONFIG_BASE_GAS,
            abi.encodeCall(IMarketRegistry.getMarket, (marketId)),
            MARKET_LENGTH
        );
        return ok && _marketMatches(ret) ? 0 : LPOracleCodes.CHECK_MARKET;
    }

    function _ownMarketWords(
        bytes memory ret,
        uint256 head
    ) private view returns (bool) {
        uint256[5] memory w = [uint256(0), 0, 0, 0, 0];
        for (uint256 i = 0; i < 5; ++i) {
            bool ok;
            (ok, w[i]) = LPOracleCalls.wordAt(ret, head + (5 + i) * WORD);
            if (!ok) return false;
        }
        return _isOwnMarket(w[0], w[1], w[2], w[3], w[4]);
    }

    /// @dev Whether the registry's `Market` record matches this feed's integration, decimals, market and tokens.
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
        if (!_ownMarketWords(ret, head)) return false;
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
