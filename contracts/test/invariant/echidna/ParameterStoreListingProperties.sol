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

    /// @notice `setFeed` with feed decimals outside 9–18. A feed of 9 to 18 decimals has an entry point of its own
    /// (`setFeed9` … `setFeed18`), where the exponent of the normalised-minimum check is concrete; here those
    /// decimals move to 19–28, which are refused as well, so every other decimals value stays symbolic.
    function setFeed(
        uint8 decimals,
        int192 lo,
        int192 hi
    ) external {
        if (decimals > 8 && decimals <= 18) decimals += 10;
        _setFeed(decimals, lo, hi, 1);
    }

    /// @notice `setFeed` with a feed of 9 to 18 decimals, one entry point per value.
    function setFeed9(
        int192 lo,
        int192 hi
    ) external {
        _setFeed(9, lo, hi, 1e1);
    }

    function setFeed10(
        int192 lo,
        int192 hi
    ) external {
        _setFeed(10, lo, hi, 1e2);
    }

    function setFeed11(
        int192 lo,
        int192 hi
    ) external {
        _setFeed(11, lo, hi, 1e3);
    }

    function setFeed12(
        int192 lo,
        int192 hi
    ) external {
        _setFeed(12, lo, hi, 1e4);
    }

    function setFeed13(
        int192 lo,
        int192 hi
    ) external {
        _setFeed(13, lo, hi, 1e5);
    }

    function setFeed14(
        int192 lo,
        int192 hi
    ) external {
        _setFeed(14, lo, hi, 1e6);
    }

    function setFeed15(
        int192 lo,
        int192 hi
    ) external {
        _setFeed(15, lo, hi, 1e7);
    }

    function setFeed16(
        int192 lo,
        int192 hi
    ) external {
        _setFeed(16, lo, hi, 1e8);
    }

    function setFeed17(
        int192 lo,
        int192 hi
    ) external {
        _setFeed(17, lo, hi, 1e9);
    }

    function setFeed18(
        int192 lo,
        int192 hi
    ) external {
        _setFeed(18, lo, hi, 1e10);
    }

    /// @dev Success exactly when the decimals are in `[1, 18]`, the minimum is positive with a normalised value of at
    /// least 1, and the pinned maximum is above the minimum. `minLo` is the smallest minimum whose normalised value
    /// `⌊lo × 10⁸ / 10^decimals⌋` is at least 1: `10^(decimals − 8)` above 8 decimals, a literal per entry point, and
    /// 1 at 8 or fewer (`lo × 10^(8 − decimals) ≥ 1` for every positive `lo`), so no exponent is computed here.
    function _setFeed(
        uint8 decimals,
        int192 lo,
        int192 hi,
        uint256 minLo
    ) internal {
        FEED.setBounds(decimals, lo, hi);
        FeedDef memory d;
        (d.feedHeartbeat, d.heartbeatMargin, d.feedDeviationThresholdBps) = (3600, 600, 25);
        (d.feedMaxAge, d.liquidationPriceMaxAge, d.borrowPriceMaxAge) = (4200, 4200, 4200);
        d.maxAnswerCap = type(int256).max;
        bool ok = _call(LISTING, abi.encodeCall(IParameterStoreListing.setFeed, (address(FEED), d)));
        bool normalised = decimals >= 1 && decimals <= 18 && lo > 0 && uint256(int256(lo)) >= minLo;
        assert(ok == (normalised && hi > lo));
    }
}
