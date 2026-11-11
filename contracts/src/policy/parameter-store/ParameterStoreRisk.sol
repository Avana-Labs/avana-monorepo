// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICoverageSpoke} from "../../coverage/coverage-spoke/ICoverageSpoke.sol";
import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4PriceFeed} from "../../interfaces/external/aave/IAaveV4PriceFeed.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {Market} from "../../types/Market.sol";
import {PledgeCounters} from "../../types/PledgeCounters.sol";
import {DebtReserveDef} from "../market-registry/types/DebtReserveDef.sol";
import {ParameterStoreOracle} from "./ParameterStoreOracle.sol";

/// @title ParameterStoreRisk
/// @notice The checks that read Aave and the Avana Umbrella: liquidation liveness of a (market, debt reserve) pair,
/// the Hub `addCap` sizing of SPEC-CAP-006, and the approved debt reserves of a debt asset (their Coverage Spoke
/// minimums and price sources).
/// @dev Every call is a view; a call that reverts or returns an unusable value counts as a failed check, so the
/// setter that needs it reverts and the view that reports it returns false.
/// @custom:spec REQ-PSTORE-021, SPEC-CAP-006, REQ-RISK-044, REQ-RISK-045, REQ-PSTORE-016, REQ-CONFIG-050
// The loops below walk the MarketRegistry's markets, Spokes and debt reserves with view calls at execution of a
// governance setter (or in a view); their length is the registry's size, which only timelock operations grow.
// forge-lint: disable-start(calls-loop)
abstract contract ParameterStoreRisk is ParameterStoreOracle {
    /// @dev `minLB = 10⁴ + ⌊(maxLiquidationBonus − 10⁴) × liquidationBonusFactor / 10⁴⌋` of the latest dynamic key of
    /// the market's reserve on its Spoke, resolved through its Hub (so it answers before activation); 0 when any read
    /// fails or `maxLiquidationBonus < 10⁴`.
    /// @custom:spec REQ-PSTORE-021, SPEC-HUB-005
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
    /// @custom:spec REQ-PSTORE-021
    function _inequality(
        uint256 minLb,
        uint256 sMin,
        uint256 f
    ) internal pure returns (bool) {
        if (sMin >= BPS || f >= BPS) return false;
        return minLb * (BPS - sMin) >= BPS * (BPS + f);
    }

    /// @dev Whether the Spoke has at least one enabled debt reserve.
    function _hasEnabledReserve(
        address spoke
    ) private view returns (bool any) {
        uint256[] memory ids = _REGISTRY.getDebtReserveIds(spoke);
        for (uint256 i = 0; i < ids.length; ++i) {
            if (_REGISTRY.isApprovedDebtReserve(spoke, ids[i])) any = true;
        }
    }

    /// @dev The liveness inequality of market `m` against every enabled debt reserve of its Spoke. Every pair of one
    /// market shares `minLB`, the floor and the flash ceiling, so one evaluation covers all of them.
    /// @custom:spec REQ-PSTORE-021, REQ-CONFIG-052
    function _requireLiveness(
        Market memory m,
        uint256 sMin,
        uint256 f
    ) internal view {
        if (_hasEnabledReserve(m.spoke) && !_inequality(_minLb(m), sMin, f)) revert LivenessBound();
    }

    /// @dev The liveness inequality with flash ceiling `f` for every Active or Offboarding market of every CDP Spoke.
    /// @custom:spec REQ-PSTORE-021, REQ-PSTORE-024
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

    /// @dev SPEC-CAP-006 for an Active or Offboarding market: `addCap ≥ ⌈(max(cap, R) + max(slice, S)) / floor⌉`
    /// whole vault tokens, or `addCap == MAX_ALLOWED_SPOKE_CAP`, with `R`, `S` the market's booked counters. A
    /// Registered market has no Hub asset yet; `activateMarket` checks the bound. Reverts `AddCapTooSmall`, also for a
    /// zero floor, which no setter writes.
    /// @custom:spec SPEC-CAP-006, REQ-RISK-044, REQ-RISK-045
    function _requireAddCap(
        Market memory m,
        uint256 cap,
        uint256 slice,
        uint256 floor
    ) internal view {
        if (!_live(m.status)) return;
        // Every written floor is > 0 (setInitialMarketCaps, setStressFloorUsd); a zero floor fails closed before the
        // division below.
        if (floor == 0) revert AddCapTooSmall();
        IAaveV4Hub hub = IAaveV4Hub(m.hub);
        uint256 addCap = hub.getSpokeConfig(m.hubAssetId, m.spoke).addCap;
        if (addCap == hub.MAX_ALLOWED_SPOKE_CAP()) return;
        PledgeCounters memory c =
            ICollateralizationViews(_REGISTRY.COLLATERALIZATION()).getCounters(m.vaultToken, address(0));
        uint256 usd = (cap > c.regularUsed ? cap : c.regularUsed) + (slice > c.sliceUsed ? slice : c.sliceUsed);
        if (addCap < (usd + floor - 1) / floor) revert AddCapTooSmall();
    }

    /// @dev Walks every approved debt reserve of `asset` on every CDP Spoke (funded by `hub` when `hub` is not zero):
    /// whether one exists, the smallest `firstLossReserveMinimum()` of their Coverage Spokes (only when `hub` is set),
    /// the largest 8-decimal price their price sources report (only when `hub` is zero; a failed or non-positive read
    /// counts as unbounded) and the asset's decimals.
    /// @custom:spec REQ-PSTORE-016, REQ-CONFIG-050, REQ-PSTORE-006
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
                    uint256 minimum = ICoverageSpoke(d.coverageSpoke).firstLossReserveMinimum();
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

    /// @dev A rounding allowance worth at most $1 at the largest price of the asset's approved debt reserves,
    /// `v × price ≤ 10⁸ × 10^decimals` (exact, as `v ≤ ⌊10⁸ × 10^decimals / price⌋`). Reverts `TokenNotListed` when no
    /// approved debt reserve uses the asset and `OutOfBounds` outside `(0, max]`.
    /// @custom:spec REQ-CONFIG-050, REQ-PSTORE-006, Q-380, Q-397
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
