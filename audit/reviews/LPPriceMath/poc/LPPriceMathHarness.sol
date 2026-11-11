// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPPriceMath} from "../src/oracle/lp-oracle/LPPriceMath.sol";
import {PriceState} from "../src/types/PriceState.sol";

/// @title LPPriceMathHarness
/// @notice External entry points over the internal library LPPriceMath, for the unit, fuzz, differential and Halmos
/// suites, plus two stand-in compositions for `vaultDecimals`: a table of amounts per vault-token decimals (golden
/// vectors from the concentrated-liquidity examples of 2.10) and a linear composition `a_i = floor(units * c_i / 10^18)`.
contract LPPriceMathHarness {
    /// @notice Amounts per candidate decimals `d` (index `d`), set by `setCompositionTable`.
    mapping(uint256 d => uint256[] amounts) internal table;
    /// @notice Raw token units per 10^18 vault-token units, set by `setLinearComposition`.
    uint256[] internal coefficients;

    function setCompositionTable(
        uint8 d,
        uint256[] calldata amounts
    ) external {
        table[d] = amounts;
    }

    function setLinearComposition(
        uint256[] calldata perWad
    ) external {
        coefficients = perWad;
    }

    function normalizeAnswer(
        uint256 answer,
        uint8 decimals
    ) external pure returns (uint256) {
        return LPPriceMath.normalizeAnswer(answer, decimals);
    }

    function routeValue1(
        uint256 answer,
        uint8 decimals
    ) external pure returns (uint256) {
        return LPPriceMath.routeValue(answer, decimals);
    }

    function routeValue2(
        uint256 answerA,
        uint8 decimalsA,
        uint256 answerB,
        uint8 decimalsB
    ) external pure returns (uint256) {
        return LPPriceMath.routeValue(answerA, decimalsA, answerB, decimalsB);
    }

    function routeTimestamp(
        uint64 a,
        uint64 b
    ) external pure returns (uint64) {
        return LPPriceMath.routeTimestamp(a, b);
    }

    function feedMaxAge(
        uint32 heartbeat,
        uint32 margin
    ) external pure returns (uint64) {
        return LPPriceMath.feedMaxAge(heartbeat, margin);
    }

    function routesAgree(
        uint256 p,
        uint256 b,
        uint16 t
    ) external pure returns (bool) {
        return LPPriceMath.routesAgree(p, b, t);
    }

    function secondSourceAgrees(
        bool valid,
        uint256 q,
        uint256 s,
        uint16 t
    ) external pure returns (bool) {
        return LPPriceMath.secondSourceAgrees(valid, q, s, t);
    }

    function deviationBps(
        uint256 x,
        uint256 y
    ) external pure returns (uint256) {
        return LPPriceMath.deviationBps(x, y);
    }

    function valuationPrice(
        uint256 q,
        bool stable
    ) external pure returns (uint256) {
        return LPPriceMath.valuationPrice(q, stable);
    }

    function lpPrice(
        uint256[] memory amounts,
        uint256[] memory prices,
        uint8[] memory decimals
    ) external pure returns (uint256) {
        return LPPriceMath.lpPrice(amounts, prices, decimals);
    }

    function vaultDecimalsFromTable(
        uint256[] memory prices,
        uint8[] memory decimals
    ) external view returns (bool, uint8) {
        return LPPriceMath.vaultDecimals(_tableComposition, prices, decimals);
    }

    function vaultDecimalsLinear(
        uint256[] memory prices,
        uint8[] memory decimals
    ) external view returns (bool, uint8) {
        return LPPriceMath.vaultDecimals(_linearComposition, prices, decimals);
    }

    function linearComposition(
        uint256 units
    ) external view returns (uint256[] memory) {
        return _linearComposition(units, new uint256[](0));
    }

    function inUsdBand(
        uint256[] memory q,
        uint256[] memory v,
        uint256 low,
        uint256 high
    ) external pure returns (bool) {
        return LPPriceMath.inUsdBand(q, v, low, high);
    }

    function fixedPointProduct(
        uint256[] memory xs
    ) external pure returns (uint256) {
        return LPPriceMath.fixedPointProduct(xs);
    }

    function fixedPointPower(
        uint256 b,
        uint256 n
    ) external pure returns (uint256) {
        return LPPriceMath.fixedPointPower(b, n);
    }

    function servedTimestamp(
        uint64[] memory t,
        bool failed,
        uint64 acceptedUpdatedAt
    ) external pure returns (uint64) {
        return LPPriceMath.servedTimestamp(t, failed, acceptedUpdatedAt);
    }

    function ageLimits(
        LPPriceMath.LegAge[] memory legs,
        bool failed
    ) external pure returns (uint32, uint32) {
        return LPPriceMath.ageLimits(legs, failed);
    }

    function servedPrice(
        PriceState state,
        bool disagreeing,
        uint256 fresh,
        uint256 lower,
        uint256 accepted
    ) external pure returns (uint256) {
        return LPPriceMath.servedPrice(state, disagreeing, fresh, lower, accepted);
    }

    function debtServedPrice(
        PriceState state,
        uint256 q,
        uint256 p,
        uint256 b,
        uint256 accepted,
        uint256 rise
    ) external pure returns (uint256) {
        return LPPriceMath.debtServedPrice(state, q, p, b, accepted, rise);
    }

    function sequencerStatus(
        bool hasFeed,
        bool readOk,
        int256 answer,
        uint256 startedAt,
        uint256 nowTs,
        uint256 gracePeriod
    ) external pure returns (bool, bool, bool, bool, bool) {
        return LPPriceMath.sequencerStatus(hasFeed, readOk, answer, startedAt, nowTs, gracePeriod);
    }

    function minObservations(
        uint256 window,
        uint256 blockTime
    ) external pure returns (uint256) {
        return LPPriceMath.minObservations(window, blockTime);
    }

    function gasForCall(
        uint256 g
    ) external pure returns (uint256) {
        return LPPriceMath.gasForCall(g);
    }

    function pokeMinGasFloor(
        uint256 w,
        uint256 g
    ) external pure returns (uint256) {
        return LPPriceMath.pokeMinGasFloor(w, g);
    }

    function _tableComposition(
        uint256 units,
        uint256[] memory
    ) internal view returns (uint256[] memory) {
        uint256 d = 0;
        while (units >= 10) {
            units /= 10;
            ++d;
        }
        return table[d];
    }

    function _linearComposition(
        uint256 units,
        uint256[] memory
    ) internal view returns (uint256[] memory amounts) {
        uint256 n = coefficients.length;
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            amounts[i] = units * coefficients[i] / 1e18;
        }
    }
}
