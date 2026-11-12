// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStoreChain} from "../../../src/policy/parameter-store/IParameterStoreChain.sol";
import {IParameterStoreListing} from "../../../src/policy/parameter-store/IParameterStoreListing.sol";
import {ParameterStoreListingLogic} from "../../../src/policy/parameter-store/ParameterStoreListingLogic.sol";
import {FeedDef} from "../../../src/policy/parameter-store/types/FeedDef.sol";
import {MarketParams} from "../../../src/policy/parameter-store/types/MarketParams.sol";
import {SecondSourceKind} from "../../../src/types/SecondSourceKind.sol";
import {MockAggregator} from "../../utils/mocks/ParameterStoreMocks.sol";
import {ParameterStoreHarnessBase} from "./ParameterStoreHarnessBase.sol";

/// @title ParameterStoreListingProperties
/// @notice Echidna and Medusa properties of the ParameterStore's listing logic on an L2 (a sequencer): whatever
/// sequence of sequencer, market-parameter and feed writes runs, every TWAP window stays within the sequencer grace
/// (REQ-PSTORE-034), a pinned feed's bounds stay inside the aggregator's `int192` range with the maximum above the
/// minimum (REQ-CONFIG-022), and each setter succeeds exactly when its predicate holds.
/// @dev USDT carries a pool-TWAP second source with a 900-second window, written straight into the layout, so the
/// grace has a second-source window to cover besides the market's.
contract ParameterStoreListingProperties is ParameterStoreHarnessBase {
    uint32 internal constant SOURCE_WINDOW = 900;

    address internal immutable LISTING;
    MockAggregator internal immutable SEQ;
    MockAggregator internal immutable FEED;

    constructor() ParameterStoreHarnessBase(true) {
        LISTING = address(new ParameterStoreListingLogic(address(this), address(_REGISTRY), 12, true));
        SEQ = new MockAggregator(0, 0, 0);
        SEQ.setRound(0, 1);
        FEED = new MockAggregator(8, 1e6, 1e12);
        Layout storage $ = _s();
        $.secondSource[USDT].kind = SecondSourceKind.PoolTwap;
        $.secondSource[USDT].source = address(INTEGRATION);
        $.secondSource[USDT].poolRef = bytes32(uint256(0xC0FFEE));
        $.secondSource[USDT].twapWindow = SOURCE_WINDOW;
        $.secondSource[USDT].toleranceBps = 120;
        $.sequencer.feed = address(SEQ);
        $.sequencer.gracePeriod = 3600;
    }

    // ─── Properties ───

    function property_windowsWithinGrace() external view returns (bool) {
        return _windowsFitGrace();
    }

    function property_pinnedFeedInRange() external view returns (bool) {
        FeedDef storage d = _s().feeds[address(FEED)];
        return d.decimals == 0
            || (d.minAnswer >= 1 && d.maxAnswer > d.minAnswer && d.maxAnswer <= type(int192).max && d.decimals <= 18);
    }

    // ─── Assertion entry points ───

    function setSequencer(
        uint32 grace
    ) external {
        uint32 window = _s().market[M].twapWindow;
        bool ok = _call(LISTING, abi.encodeCall(IParameterStoreChain.setSequencer, (address(SEQ), grace)));
        bool fits = grace >= window && grace >= SOURCE_WINDOW;
        assert(ok == (grace >= 600 && grace <= 7200 && fits && ORACLE.failed() == 0));
    }

    function listMarket(
        uint32 window
    ) external {
        MarketParams memory p = _s().market[M];
        p.twapWindow = window;
        uint32 grace = _s().sequencer.gracePeriod;
        bool ok = _call(LISTING, abi.encodeCall(IParameterStoreListing.setInitialMarketParams, (M, p)));
        // A 12-second chain needs ⌈window / 12⌉ + 1 observations; the pool holds 1,000.
        bool predicate = window != 0 && window <= grace && (uint256(window) + 11) / 12 + 1 <= 1000;
        assert(ok == (predicate && ORACLE.failed() == 0));
    }

    function setFeed(
        uint8 decimals,
        int192 lo,
        int192 hi
    ) external {
        FEED.setBounds(decimals, lo, hi);
        FeedDef memory d;
        (d.feedHeartbeat, d.heartbeatMargin, d.feedDeviationThresholdBps) = (3600, 600, 25);
        (d.feedMaxAge, d.liquidationPriceMaxAge, d.borrowPriceMaxAge) = (4200, 4200, 4200);
        d.maxAnswerCap = type(int256).max;
        bool ok = _call(LISTING, abi.encodeCall(IParameterStoreListing.setFeed, (address(FEED), d)));
        bool inRange = decimals >= 1 && decimals <= 18 && lo > 0;
        // ⌊lo × 10⁸ / 10^decimals⌋ ≥ 1, or lo × 10^(8 − decimals) ≥ 1 below 8 decimals (always, lo being positive).
        bool normalised = inRange && (decimals < 8 || uint256(int256(lo)) * 1e8 / 10 ** decimals != 0);
        bool predicate = normalised && hi > lo;
        assert(ok == predicate);
    }
}
