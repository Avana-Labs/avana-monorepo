// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ParameterStoreRisk
/// @notice Checks that read Aave and the First-Loss Reserves: liquidation liveness, `addCap` sizing, debt reserves.
/// @dev A call that reverts or returns an unusable value counts as a failed check.
// Loop lengths are the registry's size, which only timelock operations grow.

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {IntegrationCapabilities} from "../../amm/types/IntegrationCapabilities.sol";
import {RiskStatus} from "../../amm/types/RiskStatus.sol";
import {IAvanaFirstLossReserve} from "../../coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4PriceFeed} from "../../interfaces/external/aave/IAaveV4PriceFeed.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {Market} from "../../types/Market.sol";
import {PledgeCounters} from "../../types/PledgeCounters.sol";
import {SecondSource} from "../../types/SecondSource.sol";
import {SecondSourceKind} from "../../types/SecondSourceKind.sol";
import {ShapeKind} from "../../types/ShapeKind.sol";
import {DebtReserveDef, TokenDef} from "../market-registry/types/MarketRegistryTypes.sol";
import {IParameterStore} from "./IParameterStore.sol";
import {IPoolObservations} from "./IPoolObservations.sol";
import {ParameterStoreStorage} from "./ParameterStoreStorage.sol";
import {FeedDef} from "./types/ParameterStoreTypes.sol";

// forge-lint: disable-start(calls-loop)
abstract contract ParameterStoreRisk is ParameterStoreStorage {
    // forge-lint: disable-start(calls-loop)
    // forge-lint: disable-start(reentrancy-events)
    /// @dev `⌈window / CHAIN_BLOCK_TIME⌉ + 1`, 0 for no window, saturated at `type(uint16).max`.
    function _twapMinObservations(
        uint32 window
    ) internal view returns (uint16) {
        if (window == 0) return 0;
        uint256 count = (uint256(window) + _BLOCK_TIME - 1) / _BLOCK_TIME + 1;
        // Saturated: the cast runs only for count <= type(uint16).max.
        // forge-lint: disable-next-line(unsafe-typecast)
        return count > type(uint16).max ? type(uint16).max : uint16(count);
    }

    /// @dev Covers every route pair a standby switch can put in force; saturates at `type(uint16).max` (fails closed).
    function _toleranceMin(
        address token
    ) internal view returns (uint16) {
        TokenDef memory def = _REGISTRY.getToken(token);
        uint256 p = _sum(def.primaryRoute, false);
        uint256 a = _sum(def.alternateRoute, false);
        uint256 sb = _sum(def.standbyRoute, false);
        uint256 pair = p + a;
        if (sb + a > pair) pair = sb + a;
        if (p + sb > pair) pair = p + sb;
        uint256 sum = pair + _s().g.feedAgreementMarginBps;
        // Saturated: the cast runs only for sum <= type(uint16).max.
        // forge-lint: disable-next-line(unsafe-typecast)
        return sum > type(uint16).max ? type(uint16).max : uint16(sum);
    }

    function _sum(
        address[] memory feeds,
        bool drift
    ) private view returns (uint256 total) {
        for (uint256 i = 0; i < feeds.length; ++i) {
            FeedDef storage d = _s().feeds[feeds[i]];
            total += d.feedDeviationThresholdBps;
            if (drift) total += d.heartbeatDriftBps;
        }
    }

    function _toleranceHolds(
        address token
    ) internal view returns (bool) {
        return _s().feedAgreementToleranceBps[token] >= _toleranceMin(token);
    }

    function _checkLpOracle(
        address lpOracle
    ) internal view {
        uint256 failed = _configFailures(lpOracle);
        if (failed != 0) revert OracleConfigRejected(lpOracle, failed);
    }

    /// @dev The `checkConfig` bitmap of `lpOracle` for the configuration in storage, `2²⁵⁶ − 1` on a failed call.
    function _configFailures(
        address lpOracle
    ) internal view returns (uint256 failed) {
        // Self-call to the proxy's own view; the returned bytes are forwarded unchanged (no re-encoding).
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory config) =
            address(this).staticcall(abi.encodeCall(IParameterStore.getOracleConfig, (lpOracle)));
        failed = type(uint256).max;
        if (ok && lpOracle.code.length != 0) {
            // The LPOracle's view, called with the configuration bytes above.
            // solhint-disable-next-line avoid-low-level-calls
            (bool done, bytes memory ret) = lpOracle.staticcall(bytes.concat(ILPOracle.checkConfig.selector, config));
            if (done && ret.length == 32) failed = abi.decode(ret, (uint256));
        }
    }

    /// @dev Reverts `LivenessBound` for a tolerance below its bound, then `OracleConfigRejected` for a failed check.
    function _recheck(
        uint8 scope,
        address key,
        bool tolerance
    ) internal view {
        _recheck(scope, key, tolerance, false);
    }

    /// @dev `_recheck`; with `fit`, every affected market must also pass `_marketFits` (`OutOfBounds`).
    function _recheck(
        uint8 scope,
        address key,
        bool tolerance,
        bool fit
    ) internal view {
        (address[] memory oracles, bool toleranceBroken, bool misfit) = _affected(scope, key, tolerance, fit);
        if (toleranceBroken) revert LivenessBound();
        if (misfit) revert OutOfBounds();
        address rejected = address(0);
        uint256 rejectedChecks = 0;
        for (uint256 i = 0; i < oracles.length; ++i) {
            if (oracles[i] == address(0) || rejected != address(0)) continue;
            uint256 failed = _configFailures(oracles[i]);
            if (failed != 0) (rejected, rejectedChecks) = (oracles[i], failed);
        }
        if (rejected != address(0)) revert OracleConfigRejected(rejected, rejectedChecks);
    }

    /// @dev The affected LPOracles, one slot per market identifier, plus tolerance and fit failures when requested.
    function _affected(
        uint8 scope,
        address key,
        bool tolerance,
        bool fit
    ) internal view returns (address[] memory oracles, bool toleranceBroken, bool misfit) {
        uint256 count = _REGISTRY.marketCount();
        oracles = new address[](count);
        for (uint256 id = 1; id <= count; ++id) {
            Market memory m = _REGISTRY.getMarket(id);
            if (!_configured(m.status)) continue;
            bool hit = scope == SCOPE_ALL;
            for (uint256 i = 0; i < m.tokens.length; ++i) {
                if (!_tokenHit(m.tokens[i], scope, key)) continue;
                hit = true;
                if (tolerance && !_toleranceHolds(m.tokens[i])) toleranceBroken = true;
            }
            if (!hit) continue;
            oracles[id - 1] = m.lpOracle;
            if (fit && !_marketFits(m, _s().market[id].twapWindow)) misfit = true;
        }
    }

    function _tokenHit(
        address token,
        uint8 scope,
        address key
    ) private view returns (bool) {
        return
            scope == SCOPE_ALL || (scope == SCOPE_TOKEN && token == key)
                || (scope == SCOPE_FEED && _usesFeed(token, key));
    }

    /// @dev Entry `i` uses the recorded second sources, entry `n + i` the standbys; switches are undone before return.
    function _failures(
        address[] memory oracles
    ) internal returns (uint256[] memory failed) {
        uint256 n = oracles.length;
        failed = new uint256[](2 * n);
        for (uint256 i = 0; i < n; ++i) {
            if (oracles[i] == address(0)) continue;
            failed[i] = _configFailures(oracles[i]);
            address[] memory tokens = _REGISTRY.getMarket(i + 1).tokens;
            uint256 switched = _switchStandbys(tokens, 0);
            if (switched == 0) continue;
            failed[n + i] = _configFailures(oracles[i]);
            switched = _switchStandbys(tokens, switched);
        }
    }

    /// @dev With `undo == 0`, switches each token with a standby onto it and returns the mask; else switches back.
    function _switchStandbys(
        address[] memory tokens,
        uint256 undo
    ) private returns (uint256 mask) {
        Layout storage $ = _s();
        for (uint256 j = 0; j < tokens.length; ++j) {
            address t = tokens[j];
            bool flip = undo == 0 ? $.standby[t].kind != SecondSourceKind.None && !$.onStandby[t] : (undo >> j) & 1 == 1;
            if (!flip) continue;
            // A transient switch of at most MAX_POOL_TOKENS slots, undone in the same call.
            $.onStandby[t] = undo == 0;
            mask |= 1 << j;
        }
    }

    /// @dev Only a check that passed before the write and fails after it reverts (`OracleConfigRejected`).
    function _requireNoNewFailures(
        address[] memory oracles,
        uint256[] memory before
    ) internal {
        uint256[] memory failed = _failures(oracles);
        uint256 n = oracles.length;
        address rejected = address(0);
        uint256 added = 0;
        for (uint256 k = 0; k < 2 * n; ++k) {
            address oracle = oracles[k % n];
            if (oracle == address(0) || rejected != address(0)) continue;
            uint256 more = failed[k] & ~before[k];
            if (more != 0) (rejected, added) = (oracle, more);
        }
        if (rejected != address(0)) revert OracleConfigRejected(rejected, added);
    }

    /// @dev `window ≤ gracePeriod` on a chain with a sequencer, so post-restart reads lie after the restart.
    function _withinGrace(
        uint32 window
    ) internal view returns (bool) {
        return !_HAS_SEQUENCER || window <= _s().sequencer.gracePeriod;
    }

    function _marketFits(
        Market memory m,
        uint32 twapWindow
    ) internal view returns (bool fits) {
        fits = _withinGrace(twapWindow);
        // Slot 2i is token i's recorded source, slot 2i + 1 its standby.
        for (uint256 k = 0; k < 2 * m.tokens.length; ++k) {
            address t = m.tokens[k >> 1];
            if (!_sourceFits(m, k & 1 == 0 ? _s().secondSource[t] : _s().standby[t])) fits = false;
        }
    }

    /// @dev A `PoolTwap` source must not read the market's own pool and its window must fit the sequencer grace.
    function _sourceFits(
        Market memory m,
        SecondSource storage s
    ) private view returns (bool) {
        if (s.kind != SecondSourceKind.PoolTwap) return true;
        bytes32 ref = s.poolRef;
        // An address-keyed pool's reference is `bytes32(uint160(pool))`, the word `_a` builds.
        bool ownPool = (m.pool != address(0) && ref == _a(m.pool)) || (m.poolId != bytes32(0) && ref == m.poolId);
        return !ownPool && _withinGrace(s.twapWindow);
    }

    function _usesFeed(
        address token,
        address feed
    ) internal view returns (bool) {
        TokenDef memory def = _REGISTRY.getToken(token);
        if (
            _contains(def.primaryRoute, feed) || _contains(def.alternateRoute, feed)
                || _contains(def.standbyRoute, feed)
        ) return true;
        return _isNetworkSource(_s().secondSource[token], feed) || _isNetworkSource(_s().standby[token], feed);
    }

    function _isNetworkSource(
        SecondSource storage src,
        address feed
    ) private view returns (bool) {
        return src.kind == SecondSourceKind.OracleNetwork && src.source == feed;
    }

    function _contains(
        address[] memory list,
        address a
    ) internal pure returns (bool found) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == a) found = true;
        }
    }

    /// @dev `window` must be 0 exactly when the AMM protocol has no TWAP; reverts `OutOfBounds`.
    function _checkTwap(
        uint256 marketId,
        Market memory m,
        uint32 window
    ) internal view {
        if (!_withinGrace(window)) revert OutOfBounds();
        IntegrationCapabilities memory caps = IAmmIntegration(m.integration).capabilities();
        if (!caps.hasTwap) {
            if (window != 0) revert OutOfBounds();
            return;
        }
        if (window == 0) revert OutOfBounds();
        uint256 need = (uint256(window) + _BLOCK_TIME - 1) / _BLOCK_TIME + 1;
        if (need > type(uint16).max) revert OutOfBounds();
        if (caps.shapeKind == ShapeKind.TickRange && m.pool != address(0)) {
            // Only the observation cardinality is compared; price, tick and index are not used.
            // forge-lint: disable-next-line(unused-return)
            (,,, uint16 cardinality) = IPoolObservations(m.pool).slot0();
            if (cardinality < need) revert OutOfBounds();
        }
        try IAmmIntegration(m.integration).riskStatus(marketId, window) returns (RiskStatus memory st) {
            if (!st.depthAvailable) revert OutOfBounds();
        } catch {
            revert OutOfBounds();
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
            if (
                _sum(def.primaryRoute, true) >= margin || _sum(def.alternateRoute, true) >= margin
                    || _sum(def.standbyRoute, true) >= margin
            ) holds = false;
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
            ICollateralizationViews(_REGISTRY.COLLATERALIZATION()).getCounters(m.vaultToken, address(0));
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
