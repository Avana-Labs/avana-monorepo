// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaFirstLossReserve} from "../../coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {IFlashSource} from "../../flash/IFlashSource.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4PriceFeed} from "../../interfaces/external/aave/IAaveV4PriceFeed.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ITetherFee} from "../../interfaces/external/tether/ITetherFee.sol";
import {RouteMath} from "../../liquidation/settlement-routes/RouteMath.sol";
import {IParameterStore} from "../parameter-store/IParameterStore.sol";
import {FeedDef} from "../parameter-store/types/ParameterStoreTypes.sol";
import {RiskModuleMath} from "../risk-module/RiskModuleMath.sol";
import {IMarketRegistry} from "./IMarketRegistry.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";
import {IssuerProbes} from "./types/IssuerProbe.sol";
import {DebtReserveDef, RiskTier} from "./types/MarketRegistryTypes.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title MarketRegistryDebtChecks
/// @notice The checks `enableDebtReserve` runs on a debt-reserve definition, and its liveness check.
/// @dev Every call made here is a view.
// ParameterStore liveness views over the Spoke's live markets; views only.
// forge-lint: disable-start(calls-loop)
abstract contract MarketRegistryDebtChecks is MarketRegistryStorage {
    function _checkFunding(
        address spoke,
        address homeHub,
        DebtReserveDef calldata def
    ) internal view {
        bool cross = def.fundingHub != homeHub;
        if (def.crossHub != cross) revert InvalidDebtReserve("crossHub");
        if (!cross) return;
        Layout storage l = _s();
        if (!l.crossHubLinesEnabled) revert IMarketRegistry.CrossHubLinesDisabled();
        if (l.crossHubLineCap[def.fundingHub][def.asset][spoke] == 0) {
            revert IMarketRegistry.CrossHubLineClosed(def.fundingHub, def.asset, spoke);
        }
        if (l.creditLines[def.fundingHub][def.asset].line == 0) {
            revert IMarketRegistry.FundingHubConsentMissing(def.fundingHub, def.asset);
        }
    }

    function _checkAaveReserve(
        address spoke,
        DebtReserveDef calldata def
    ) internal view {
        IAaveV4Spoke s = IAaveV4Spoke(spoke);
        IAaveV4Spoke.Reserve memory r = s.getReserve(def.reserveId);
        if (
            r.underlying != def.asset || r.hub != def.fundingHub || r.assetId != def.hubAssetId
                || r.decimals != def.decimals || IERC20Metadata(def.asset).decimals() != def.decimals
        ) revert InvalidDebtReserve("reserve");
        if (!s.getReserveConfig(def.reserveId).borrowable) revert InvalidDebtReserve("borrowable");
        if (s.getDynamicReserveConfig(def.reserveId, r.dynamicConfigKey).collateralFactor != 0) {
            revert InvalidDebtReserve("collateralFactor");
        }
    }

    function _checkPriceSource(
        address spoke,
        DebtReserveDef calldata def
    ) internal view {
        address src = def.priceSource;
        if (src == address(0) || IAaveV4Oracle(IAaveV4Spoke(spoke).ORACLE()).getReserveSource(def.reserveId) != src) {
            revert InvalidDebtReserve("priceSource");
        }
        if (IAaveV4PriceFeed(src).decimals() != _ORACLE_DECIMALS) revert InvalidDebtReserve("priceSource");
        if (!_s().tokens[def.asset].listed) revert TokenNotListed(def.asset);
        if (def.fixedPrice) {
            if (IAaveV4PriceFeed(src).latestAnswer() <= 0) revert InvalidDebtReserve("priceSource");
            return;
        }
        // The source is the asset's Chainlink feed, with age limits set in the ParameterStore.
        FeedDef memory f = IParameterStore(_PARAMETER_STORE).getFeed(src);
        if (f.borrowPriceMaxAge == 0 || f.liquidationPriceMaxAge == 0) revert InvalidDebtReserve("feed");
    }

    function _checkAvanaFirstLossReserve(
        DebtReserveDef calldata def
    ) internal view {
        address cs = def.firstLossReserve;
        if (cs == address(0) || cs != _s().firstLossReserveOf[def.fundingHub][def.asset]) {
            revert IMarketRegistry.AvanaFirstLossReserveMismatch(def.fundingHub, def.asset, cs);
        }
        IAvanaFirstLossReserve c = IAvanaFirstLossReserve(cs);
        if (c.ASSET() != def.asset || c.HUB() != def.fundingHub || c.ASSET_ID() != def.hubAssetId) {
            revert InvalidDebtReserve("firstLossReserve");
        }
        if (c.isBelowMinimum()) revert IMarketRegistry.CoverageNotFunded(def.fundingHub, def.asset);
    }

    function _checkFlashAndFee(
        DebtReserveDef calldata def
    ) internal view {
        Layout storage l = _s();
        address fs = l.flashSource;
        if (fs == address(0)) revert InvalidDebtReserve("flash");
        IFlashSource f = IFlashSource(fs);
        uint256 available = f.maxFlashLoan(def.asset);
        if (available == 0 || l.hubTier[f.LENDER()] != RiskTier.None) revert InvalidDebtReserve("flash");
        uint256 premium = f.flashPremium(def.asset, available);
        uint256 maxFee = IParameterStore(_PARAMETER_STORE).maxFlashFeeBps();
        if (premium > type(uint128).max || available > type(uint128).max || premium * _BPS > maxFee * available) {
            revert InvalidDebtReserve("flash");
        }
        if (IssuerProbes.readsFeeRate(l.tokens[def.asset].issuerProbe) && !_feeRateZero(def.asset)) {
            revert TransferFeeActive(def.asset);
        }
    }

    /// @dev Reads `basisPointsRate()` as the RiskModule's breaker does; only exactly one zero word counts as zero.
    function _feeRateZero(
        address token
    ) internal view returns (bool zero) {
        if (gasleft() < RiskModuleMath.gasFloor(RiskModuleMath.ISSUER_PROBE_GAS)) return false;
        (bool ok, bytes memory ret) = RouteMath._staticRead(
            token, RiskModuleMath.ISSUER_PROBE_GAS, abi.encodeCall(ITetherFee.basisPointsRate, ()), 33
        );
        zero = ok && ret.length == 32 && abi.decode(ret, (uint256)) == 0;
    }

    function _checkMarketsLive(
        address spoke,
        uint256 reserveId,
        address asset
    ) internal view {
        Layout storage l = _s();
        uint256[] storage ids = l.marketsOfSpoke[spoke];
        uint256 failed = 0;
        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (!_liquidatable(l.markets[id].status)) continue;
            if (
                !_routesCover(id, asset)
                    || !IParameterStore(_PARAMETER_STORE).liquidationLivenessHolds(spoke, id, reserveId)
            ) {
                failed = id;
                break;
            }
        }
        if (failed != 0) revert LivenessBound(spoke, failed, reserveId);
    }
}
// forge-lint: disable-end(calls-loop)
