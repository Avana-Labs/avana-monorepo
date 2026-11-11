// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICoverageSpoke} from "../../coverage/coverage-spoke/ICoverageSpoke.sol";
import {IFlashSource} from "../../flash/IFlashSource.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4PriceFeed} from "../../interfaces/external/aave/IAaveV4PriceFeed.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ITetherFee} from "../../interfaces/external/tether/ITetherFee.sol";
import {IDebtOracle} from "../../oracle/debt-oracle/IDebtOracle.sol";
import {IParameterStoreLiquidation} from "../parameter-store/IParameterStoreLiquidation.sol";
import {IParameterStoreViews} from "../parameter-store/IParameterStoreViews.sol";
import {IMarketRegistryCreditLines} from "./IMarketRegistryCreditLines.sol";
import {IMarketRegistryHubs} from "./IMarketRegistryHubs.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";
import {DebtReserveDef} from "./types/DebtReserveDef.sol";
import {IssuerProbe} from "./types/IssuerProbe.sol";
import {RiskTier} from "./types/RiskTier.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title MarketRegistryDebtChecks
/// @notice The checks `enableDebtReserve` runs on a debt-reserve definition (REQ-MREG-006, REQ-MREG-008,
/// REQ-CONFIG-081) and the liveness check against the Spoke's live markets (REQ-MREG-032).
/// @dev Every call made here is a view. Each check reverts with the named error of the interface.
/// @custom:spec REQ-MREG-006, REQ-MREG-008, REQ-MREG-009, REQ-MREG-032, REQ-CONFIG-079, REQ-CONFIG-081, INV-095
// ParameterStore liveness views over the Spoke's live markets; views only.
// forge-lint: disable-start(calls-loop)
abstract contract MarketRegistryDebtChecks is MarketRegistryStorage {
    /// @dev Same-Hub or cross-Hub funding (REQ-MREG-009, REQ-CONFIG-081): `def.crossHub` must say which, a cross-Hub
    /// line needs the chain switch on, an open line for the Spoke and a line recorded by the funding Hub.
    function _checkFunding(
        address spoke,
        address homeHub,
        DebtReserveDef calldata def
    ) internal view {
        bool cross = def.fundingHub != homeHub;
        if (def.crossHub != cross) revert InvalidDebtReserve("crossHub");
        if (!cross) return;
        Layout storage l = _s();
        if (!l.crossHubLinesEnabled) revert IMarketRegistryHubs.CrossHubLinesDisabled();
        if (l.crossHubLineCap[def.fundingHub][def.asset][spoke] == 0) {
            revert IMarketRegistryHubs.CrossHubLineClosed(def.fundingHub, def.asset, spoke);
        }
        if (l.creditLines[def.fundingHub][def.asset].line == 0) {
            revert IMarketRegistryCreditLines.FundingHubConsentMissing(def.fundingHub, def.asset);
        }
    }

    /// @dev The Aave reserve matches `def` (underlying, funding Hub, Hub asset ID, decimals equal to the token's own),
    /// is borrowable and has collateral factor 0 on its latest key.
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

    /// @dev REQ-MREG-006, REQ-MREG-008: the asset is a listed token (so its issuer probe is recorded, a fixed-price
    /// asset included); the AaveOracle source is `def.priceSource`, an 8-decimal source; without a fixed price it is the
    /// asset's DebtOracle bound to this registry and the ParameterStore and the asset's `debtStressRiseBps` is at least
    /// 100.
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
        IDebtOracle o = IDebtOracle(src);
        if (o.ASSET() != def.asset || o.MARKET_REGISTRY() != address(this) || o.PARAMETER_STORE() != _PARAMETER_STORE) {
            revert InvalidDebtReserve("debtOracle");
        }
        if (IParameterStoreLiquidation(_PARAMETER_STORE).debtStressRiseBps(def.asset) < 100) {
            revert InvalidDebtReserve("stressRise");
        }
    }

    /// @dev REQ-CONFIG-081: `def.coverageSpoke` is the recorded Coverage Spoke of `(fundingHub, asset)`, reports the
    /// same asset, Hub and Hub asset ID, and holds at least its `firstLossReserveMinimum`.
    function _checkCoverageSpoke(
        DebtReserveDef calldata def
    ) internal view {
        address cs = def.coverageSpoke;
        if (cs == address(0) || cs != _s().coverageSpokeOf[def.fundingHub][def.asset]) {
            revert IMarketRegistryCreditLines.CoverageSpokeMismatch(def.fundingHub, def.asset, cs);
        }
        ICoverageSpoke c = ICoverageSpoke(cs);
        if (c.ASSET() != def.asset || c.HUB() != def.fundingHub || c.ASSET_ID() != def.hubAssetId) {
            revert InvalidDebtReserve("coverageSpoke");
        }
        if (c.isBelowMinimum()) revert IMarketRegistryCreditLines.CoverageNotFunded(def.fundingHub, def.asset);
    }

    /// @dev The chain's IFlashSource lends the asset from a lender that is no recorded Hub, at a premium within
    /// `maxFlashFeeBps` (`phi × 10^4 ≤ maxFlashFeeBps × F` on `F = maxFlashLoan(asset)`), and the asset's transfer
    /// fee reads 0 (REQ-MREG-006, Q-386, Q-388, Q-390).
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
        uint256 maxFee = IParameterStoreViews(_PARAMETER_STORE).maxFlashFeeBps();
        if (premium > type(uint128).max || available > type(uint128).max || premium * _BPS > maxFee * available) {
            revert InvalidDebtReserve("flash");
        }
        if (l.tokens[def.asset].issuerProbe == IssuerProbe.UsdtFeeRate) {
            try ITetherFee(def.asset).basisPointsRate() returns (uint256 rate) {
                if (rate != 0) revert TransferFeeActive(def.asset);
            } catch {
                revert TransferFeeActive(def.asset);
            }
        }
    }

    /// @dev REQ-MREG-032 and REQ-CONFIG-039 for a newly enabled reserve: every Active or Offboarding market of the
    /// Spoke has a usable primary and backup route from each pool token other than the asset into it, and the
    /// liquidation liveness bound holds; else `LivenessBound` on the first failing market.
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
                    || !IParameterStoreLiquidation(_PARAMETER_STORE).liquidationLivenessHolds(spoke, id, reserveId)
            ) {
                failed = id;
                break;
            }
        }
        if (failed != 0) revert LivenessBound(spoke, failed, reserveId);
    }
}
// forge-lint: disable-end(calls-loop)
