// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStoreListing} from "../../../src/policy/parameter-store/IParameterStoreListing.sol";
import {ParameterStoreListingLogic} from "../../../src/policy/parameter-store/ParameterStoreListingLogic.sol";
import {FeedDef, MarketParams} from "../../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {MockAggregator} from "../../utils/mocks/ParameterStoreMocks.sol";
import {ParameterStoreHarnessBase} from "./ParameterStoreHarnessBase.sol";

/// @title ParameterStoreListingProperties
/// @notice Echidna and Medusa properties of the ParameterStore's listing logic: whatever sequence of market-parameter
/// and feed writes runs, the market's values stay inside their bounds, a pinned feed's bounds stay inside the
/// aggregator's `int192` range with the maximum above the minimum (REQ-CONFIG-022), and each setter succeeds exactly
/// when its predicate holds.
/// @dev The harness registry gives the market's tokens no price routes, so the listing margin always holds.
contract ParameterStoreListingProperties is ParameterStoreHarnessBase {
    address internal immutable LISTING;
    MockAggregator internal immutable FEED;

    constructor() ParameterStoreHarnessBase() {
        LISTING = address(new ParameterStoreListingLogic(address(this), address(_REGISTRY), 12));
        FEED = new MockAggregator(8, 1e6, 1e12);
    }

    // ─── Properties ───

    function property_marketParamsInRange() external view returns (bool) {
        MarketParams storage p = _s().market[M];
        return p.slippageAllowanceMinBps <= p.slippageAllowanceBps && p.slippageAllowanceBps < 10_000
            && p.poolRiskFactor >= 1 && p.poolRiskFactor <= 9000 && p.minPledgeUsd <= 100_000e8;
    }

    function property_pinnedFeedInRange() external view returns (bool) {
        FeedDef storage d = _s().feeds[address(FEED)];
        return d.decimals == 0
            || (d.minAnswer >= 1 && d.maxAnswer > d.minAnswer && d.maxAnswer <= type(int192).max && d.decimals <= 18);
    }

    // ─── Assertion entry points ───

    function listMarket(
        uint16 slippage,
        uint16 floor,
        uint16 factor,
        uint256 minPledge
    ) external {
        MarketParams memory p = MarketParams(slippage, floor, factor, minPledge);
        bool ok = _call(LISTING, abi.encodeCall(IParameterStoreListing.setInitialMarketParams, (M, p)));
        bool predicate =
            floor <= slippage && slippage < 10_000 && factor != 0 && factor <= 9000 && minPledge <= 100_000e8;
        assert(ok == predicate);
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
