// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ParameterStoreRisk
/// @notice Checks that read Aave and the First-Loss Reserves: liquidation liveness, `addCap` sizing, debt reserves.
/// @dev A call that reverts or returns an unusable value counts as a failed check.
// Loop lengths are the registry's size, which only governed operations grow.

import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4PriceFeed} from "../../interfaces/external/aave/IAaveV4PriceFeed.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ICollateralization} from "../../legacy/ICollateralization.sol";
import {IAvanaFirstLossReserve} from "../../legacy/coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {Market} from "../../types/MarketTypes.sol";
import {PledgeCounters} from "../../types/PositionTypes.sol";
import {DebtReserveDef, TokenDef} from "../market-registry/types/MarketRegistryTypes.sol";
import {ParameterStoreStorage} from "./ParameterStoreStorage.sol";
import {FeedDef} from "./types/ParameterStoreTypes.sol";

// forge-lint: disable-start(calls-loop)
abstract contract ParameterStoreRisk is ParameterStoreStorage {
    // forge-lint: disable-start(calls-loop)
    // forge-lint: disable-start(reentrancy-events)
    /// @dev Summed deviation threshold and heartbeat drift of a route's feeds, bps.
    function _sum(
        address[] memory feeds
    ) private view returns (uint256 total) {
        for (uint256 i = 0; i < feeds.length; ++i) {
            total += _feedError(_s().feeds[feeds[i]]);
        }
    }

    function _tokenHit(
        address token,
        uint8 scope,
        address key
    ) private view returns (bool) {
        return (scope == SCOPE_TOKEN && token == key) || (scope == SCOPE_FEED && _usesFeed(token, key));
    }

    function _usesFeed(
        address token,
        address feed
    ) internal view returns (bool) {
        TokenDef memory def = _REGISTRY.getToken(token);
        return _contains(def.primaryRoute, feed) || _contains(def.alternateRoute, feed);
    }

    function _contains(
        address[] memory list,
        address a
    ) internal pure returns (bool found) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == a) found = true;
        }
    }

    /// @dev Reverts `OutOfBounds` unless `10⁴ − CF_LP > dev(r) + drift(r)` for every recorded route.
    function _checkListingMargin(
        Market memory m,
        uint16 poolRiskFactor
    ) internal view {
        if (!_marginHolds(m, poolRiskFactor)) revert OutOfBounds();
    }

    function _marginHolds(
        Market memory m,
        uint16 poolRiskFactor
    ) private view returns (bool holds) {
        uint256 minCf = type(uint256).max;
        for (uint256 i = 0; i < m.tokens.length; ++i) {
            uint256 cf = _s().tokenCollateralFactorBps[m.tokens[i]];
            if (cf < minCf) minCf = cf;
        }
        if (minCf == 0) return false;
        uint256 margin = BPS - (minCf * poolRiskFactor) / BPS;
        holds = true;
        for (uint256 i = 0; i < m.tokens.length; ++i) {
            TokenDef memory def = _REGISTRY.getToken(m.tokens[i]);
            if (_sum(def.primaryRoute) >= margin || _sum(def.alternateRoute) >= margin) holds = false;
        }
    }

    function _recheckMargins(
        uint8 scope,
        address key
    ) internal view {
        uint256 count = _REGISTRY.marketCount();
        bool holds = true;
        for (uint256 id = 1; id <= count; ++id) {
            uint16 factor = _s().market[id].poolRiskFactor;
            if (factor == 0) continue;
            Market memory m = _REGISTRY.getMarket(id);
            if (!_configured(m.status)) continue;
            bool hit = false;
            for (uint256 i = 0; i < m.tokens.length; ++i) {
                if (_tokenHit(m.tokens[i], scope, key)) hit = true;
            }
            if (hit && !_marginHolds(m, factor)) holds = false;
        }
        if (!holds) revert OutOfBounds();
    }

    function _feedError(
        FeedDef storage d
    ) internal view returns (uint256) {
        return uint256(d.feedDeviationThresholdBps) + d.heartbeatDriftBps;
    }

    function _emitFeed(
        address feed,
        FeedDef storage d
    ) internal {
        emit FeedConfigured(
            feed,
            d.decimals,
            d.minAnswer,
            d.maxAnswer,
            d.feedHeartbeat,
            // Every stored margin is at most MAX_HEARTBEAT_MARGIN, which setFeed checks.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint16(d.heartbeatMargin),
            d.feedMaxAge,
            d.feedDeviationThresholdBps,
            d.heartbeatDriftBps,
            d.borrowPriceMaxAge,
            d.liquidationPriceMaxAge
        );
    }

    // forge-lint: disable-end(calls-loop)
    // forge-lint: disable-end(reentrancy-events)

    /// @dev Smallest liquidation bonus of the market's reserve, bps; 0 when any read fails.
    function _minLb(
        Market memory m
    ) internal view returns (uint256) {
        IAaveV4Spoke spoke = IAaveV4Spoke(m.spoke);
        try IAaveV4Hub(m.hub).getAssetId(m.vaultToken) returns (uint256 assetId) {
            try spoke.getReserveId(m.hub, assetId) returns (uint256 reserveId) {
                return _minLbOf(spoke, reserveId);
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }

    function _minLbOf(
        IAaveV4Spoke spoke,
        uint256 reserveId
    ) private view returns (uint256) {
        try spoke.getReserve(reserveId) returns (IAaveV4Spoke.Reserve memory res) {
            try spoke.getDynamicReserveConfig(reserveId, res.dynamicConfigKey) returns (
                IAaveV4Spoke.DynamicReserveConfig memory dyn
            ) {
                try spoke.getLiquidationConfig() returns (IAaveV4Spoke.LiquidationConfig memory lc) {
                    if (dyn.maxLiquidationBonus < BPS) return 0;
                    return BPS + ((uint256(dyn.maxLiquidationBonus) - BPS) * lc.liquidationBonusFactor) / BPS;
                } catch {
                    return 0;
                }
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }

    /// @dev `minLB × (10⁴ − sMin) ≥ 10⁴ × (10⁴ + f)`, false for `sMin ≥ 10⁴` or `f ≥ 10⁴`.
    function _inequality(
        uint256 minLb,
        uint256 sMin,
        uint256 f
    ) internal pure returns (bool) {
        if (sMin >= BPS || f >= BPS) return false;
        return minLb * (BPS - sMin) >= BPS * (BPS + f);
    }

    /// @dev Fee bound `s × minLB ≤ (10⁴ − f) × (minLB − 10⁴)`, false for `minLB < 10⁴` or `f > 10⁴`.
    function _feeBoundHolds(
        uint256 minLb,
        uint256 s,
        uint256 f
    ) internal pure returns (bool) {
        if (minLb < BPS || f > BPS) return false;
        return s * minLb <= (BPS - f) * (minLb - BPS);
    }

    function _hasEnabledReserve(
        address spoke
    ) private view returns (bool any) {
        uint256[] memory ids = _REGISTRY.getDebtReserveIds(spoke);
        for (uint256 i = 0; i < ids.length; ++i) {
            if (_REGISTRY.isApprovedDebtReserve(spoke, ids[i])) any = true;
        }
    }

    /// @dev Liveness of market `m`; one evaluation covers every debt reserve of its Spoke.
    function _requireLiveness(
        Market memory m,
        uint256 sMin,
        uint256 f
    ) internal view {
        if (_hasEnabledReserve(m.spoke) && !_inequality(_minLb(m), sMin, f)) revert LivenessBound();
    }

    /// @dev The liveness inequality with flash ceiling `f` for every Active or Offboarding market of every CDP Spoke.
    function _requireLivenessEverywhere(
        uint256 f
    ) internal view {
        address[] memory spokes = _REGISTRY.getSpokes();
        bool ok = true;
        for (uint256 s = 0; s < spokes.length; ++s) {
            if (!_hasEnabledReserve(spokes[s])) continue;
            uint256[] memory ids = _REGISTRY.marketsOfSpoke(spokes[s]);
            for (uint256 i = 0; i < ids.length; ++i) {
                Market memory m = _REGISTRY.getMarket(ids[i]);
                if (!_live(m.status)) continue;
                if (!_inequality(_minLb(m), _s().market[ids[i]].slippageAllowanceMinBps, f)) ok = false;
            }
        }
        if (!ok) revert LivenessBound();
    }

    /// @dev `_feeBoundHolds` with fee share `f` for every Active or Offboarding market; reverts `OutOfBounds`.
    function _requireFeeBoundEverywhere(
        uint256 f
    ) internal view {
        address[] memory spokes = _REGISTRY.getSpokes();
        bool ok = true;
        for (uint256 s = 0; s < spokes.length; ++s) {
            uint256[] memory ids = _REGISTRY.marketsOfSpoke(spokes[s]);
            for (uint256 i = 0; i < ids.length; ++i) {
                Market memory m = _REGISTRY.getMarket(ids[i]);
                if (!_live(m.status)) continue;
                if (!_feeBoundHolds(_minLb(m), _s().market[ids[i]].slippageAllowanceBps, f)) ok = false;
            }
        }
        if (!ok) revert OutOfBounds();
    }

    /// @dev For a live market: `addCap ≥ ⌈(max(cap, R) + max(slice, S)) / floor⌉` or unlimited, else `AddCapTooSmall`.
    function _requireAddCap(
        Market memory m,
        uint256 cap,
        uint256 slice,
        uint256 floor
    ) internal view {
        if (!_live(m.status)) return;
        // A zero floor fails closed before the division below.
        if (floor == 0) revert AddCapTooSmall();
        IAaveV4Hub hub = IAaveV4Hub(m.hub);
        uint256 addCap = hub.getSpokeConfig(m.hubAssetId, m.spoke).addCap;
        if (addCap == hub.MAX_ALLOWED_SPOKE_CAP()) return;
        PledgeCounters memory c =
            ICollateralization(_REGISTRY.COLLATERALIZATION()).getCounters(m.vaultToken, address(0));
        uint256 usd = (cap > c.regularUsed ? cap : c.regularUsed) + (slice > c.sliceUsed ? slice : c.sliceUsed);
        if (addCap < (usd + floor - 1) / floor) revert AddCapTooSmall();
    }

    /// @dev With `hub` unset, a failed price read counts as unbounded.
    function _scanReserves(
        address asset,
        address hub
    ) internal view returns (bool found, uint256 coverageMin, uint256 price, uint8 decimals) {
        coverageMin = type(uint256).max;
        address[] memory spokes = _REGISTRY.getSpokes();
        for (uint256 s = 0; s < spokes.length; ++s) {
            uint256[] memory ids = _REGISTRY.getDebtReserveIds(spokes[s]);
            for (uint256 i = 0; i < ids.length; ++i) {
                DebtReserveDef memory d = _REGISTRY.getDebtReserve(spokes[s], ids[i]);
                if (!d.approved || d.asset != asset || (hub != address(0) && d.fundingHub != hub)) continue;
                found = true;
                decimals = d.decimals;
                if (hub != address(0)) {
                    uint256 minimum = IAvanaFirstLossReserve(d.firstLossReserve).firstLossReserveMinimum();
                    if (minimum < coverageMin) coverageMin = minimum;
                } else {
                    uint256 p = _price(d.priceSource);
                    if (p > price) price = p;
                }
            }
        }
    }

    function _price(
        address source
    ) private view returns (uint256) {
        try IAaveV4PriceFeed(source).latestAnswer() returns (int256 answer) {
            // The cast runs only for a positive answer.
            // forge-lint: disable-next-line(unsafe-typecast)
            return answer > 0 ? uint256(answer) : type(uint256).max;
        } catch {
            return type(uint256).max;
        }
    }

    function _requireRoundingAllowance(
        address asset,
        uint256 v
    ) internal view {
        (bool found,, uint256 price, uint8 decimals) = _scanReserves(asset, address(0));
        if (!found) revert TokenNotListed(asset);
        if (v == 0 || decimals > 36 || v > (ROUNDING_ALLOWANCE_USD_MAX * 10 ** decimals) / price) revert OutOfBounds();
    }
}
// forge-lint: disable-end(calls-loop)
