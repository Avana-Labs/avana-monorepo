// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceStateView} from "../../types/PriceStateView.sol";
import {RouteSlot} from "../../types/RouteSlot.sol";
import {TokenPriceView} from "../../types/TokenPriceView.sol";
import {LPOraclePoke} from "./LPOraclePoke.sol";
import {Evaluation, LPOracleCodes, RouteEval, TokenEval} from "./LPOracleTypes.sol";
import {LPPriceMath} from "./LPPriceMath.sol";

/// @title LPOracleViews
/// @notice Builds the `getPriceState()` report from an evaluation (`REQ-ORACLE-042`).
/// @dev The report is computed by the same evaluation as `latestAnswer()`, so `answer == latestAnswer()` in a block.
/// A route value or age that cannot be read is reported as 0 and `type(uint64).max`; deviations of unreadable values
/// are `type(uint256).max`.
/// @custom:spec REQ-ORACLE-042, REQ-ORACLE-021, REQ-ORACLE-082
abstract contract LPOracleViews is LPOraclePoke {
    /// @dev The report of evaluation `e`.
    /// @custom:spec REQ-ORACLE-042, REQ-ORACLE-016, REQ-ORACLE-022, REQ-ORACLE-034, REQ-ORACLE-090, REQ-ORACLE-100
    function _report(
        Evaluation memory e
    ) internal view returns (PriceStateView memory v) {
        Layout storage $ = _s();
        v.state = e.state;
        v.reasons = e.reasons;
        // served >= 1 and below 2^255 (SPEC-ORC-017).
        // forge-lint: disable-next-line(unsafe-typecast)
        v.answer = int256(e.served);
        v.servedUpdatedAt = e.servedUpdatedAt;
        v.servedAge = block.timestamp > e.servedUpdatedAt ? _now64() - e.servedUpdatedAt : 0;
        v.consistencyDeviationBps = e.failed ? type(uint256).max : e.consistencyDeviationBps;
        v.consistencyToleranceBps = e.cfg.consistencyToleranceBps;
        v.usdLevel = e.failed ? 0 : LPPriceMath.usdLevel(e.quotes);
        v.sequencerReady = e.seq.ready;
        v.failureStart = e.failed ? e.failureStart : 0;
        v.cachedUntil = e.failed ? e.cachedUntil : 0;
        v.disagreeSince = e.disagreeSince;
        v.disagreementPauseActive = e.pauseActive;
        v.disagreementExpired = e.disagreementExpired;
        v.liquidationPaused = e.liquidationPaused;
        v.borrowAllowed = e.borrowAllowed;
        v.recoveredAt = $.recoveredAt;
        v.graceEndsAt = e.graceEndsAt;
        v.inGrace = e.inGrace;
        v.borrowPriceMaxAge = e.borrowMaxAge;
        v.liquidationPriceMaxAge = e.liquidationMaxAge;
        // fresh < 2^255 (SPEC-ORC-008 bounds).
        // forge-lint: disable-next-line(unsafe-typecast)
        v.freshAnswer = e.failed ? int256(0) : int256(e.fresh);
        v.acceptedAnswer = $.accepted.answer;
        v.acceptedUpdatedAt = $.accepted.updatedAt;
        uint256 n = e.tokens.length;
        v.tokens = new TokenPriceView[](n);
        for (uint256 i = 0; i < n; ++i) {
            _tokenReport(v.tokens[i], e.tokens[i], $.tokens[i]);
        }
    }

    /// @dev The per-token part of the report.
    function _tokenReport(
        TokenPriceView memory v,
        TokenEval memory t,
        address token
    ) private view {
        v.token = token;
        v.reasons = t.reasons;
        v.routeUsed = t.used;
        v.quote = t.quote;
        v.valuationPrice = t.price;
        v.updatedAt = t.updatedAt;
        (v.primaryValue, v.primaryAge) = _routeReading(t.routes[0]);
        (v.alternateValue, v.alternateAge) = _routeReading(t.routes[1]);
        v.deviationBps = LPPriceMath.deviationBps(v.primaryValue, v.alternateValue);
        v.feedAgreementToleranceBps = t.tolerance;
        v.secondSourceValue = t.secondValid ? t.secondValue : 0;
        v.secondSourceDeviationBps =
            t.secondValid ? LPPriceMath.deviationBps(t.quote, t.secondValue) : type(uint256).max;
        v.replaced = RouteSlot(t.replaced);
        v.routeVersion = t.version;
        uint8 inUse = t.chosen != 0 ? t.chosen : t.used;
        if (inUse == LPOracleCodes.ROUTE_NONE) return;
        RouteEval memory route = t.routes[inUse - 1];
        for (uint256 l = 0; l < route.legCount; ++l) {
            v.legFeeds[l] = route.legs[l].feed;
            v.legUpdatedAt[l] = route.legs[l].updatedAt;
            v.legBorrowPriceMaxAge[l] = route.legs[l].borrowAge;
            v.legLiquidationPriceMaxAge[l] = route.legs[l].liquidationAge;
        }
    }

    /// @dev A route's value and age, or `(0, type(uint64).max)` when its legs could not be read.
    function _routeReading(
        RouteEval memory route
    ) private view returns (uint256 value, uint64 age) {
        if (route.legCount == 0 || route.status == LPOracleCodes.ERROR) return (0, type(uint64).max);
        value = route.value;
        age = block.timestamp > route.updatedAt ? _now64() - route.updatedAt : 0;
    }
}
