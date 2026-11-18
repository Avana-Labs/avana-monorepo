// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwapViews} from "../../liquidation/lp-vault-swap/ILPVaultSwapViews.sol";
import {IDebtOracle} from "../../oracle/debt-oracle/IDebtOracle.sol";
import {DebtPriceView} from "../../oracle/debt-oracle/types/DebtPriceView.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {PriceAge} from "../../oracle/lp-oracle/PriceAge.sol";
import {DriftReason} from "../../types/DriftReason.sol";
import {Market} from "../../types/Market.sol";
import {PriceState} from "../../types/PriceState.sol";
import {PriceStateView} from "../../types/PriceStateView.sol";
import {TokenPriceView} from "../../types/TokenPriceView.sol";
import {IMarketRegistryCreditLines} from "../market-registry/IMarketRegistryCreditLines.sol";
import {IMarketRegistryHubs} from "../market-registry/IMarketRegistryHubs.sol";
import {MarketStatus} from "../market-registry/types/MarketStatus.sol";
import {IRiskModuleBorrowLogic} from "./IRiskModuleBorrowLogic.sol";
import {IRiskModuleBreakerLogic} from "./IRiskModuleBreakerLogic.sol";
import {IRiskModuleDriftLogic} from "./IRiskModuleDriftLogic.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";
import {RiskModuleBorrowScope} from "./RiskModuleBorrowScope.sol";
import {RiskModuleMath} from "./RiskModuleMath.sol";
import {RiskModuleImmutables} from "./types/RiskModuleImmutables.sol";

/// @title RiskModuleBorrowLogic
/// @notice Bodies of the borrow-side checks and `debtValueUsd`, and the same gates as a view for the account status.
/// @dev The oracle pokes are its only state-changing calls; their reverts propagate.
// View calls in loops over the account's reserves and the market's tokens, bounded by listings.
// forge-lint: disable-start(calls-loop)
contract RiskModuleBorrowLogic is RiskModuleBorrowScope, IRiskModuleBorrowLogic {
    constructor(
        RiskModuleImmutables memory im,
        address drift,
        address breaker
    ) RiskModuleBorrowScope(im, drift, breaker) {}

    /// @inheritdoc IRiskModuleLogic
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("RiskModuleBorrowLogic"), _IMMUTABLES_HASH);
    }

    /// @inheritdoc IRiskModuleBorrowLogic
    function preCheck(
        address proxy,
        uint256 debtReserveId,
        bool borrow
    ) external override {
        _requireSequencerUp();
        Scope memory s = _scope(proxy, debtReserveId, borrow);
        // The gates read the price state themselves, so the poke results are not used.
        // forge-lint: disable-next-line(unused-return)
        ILPOracle(s.m.lpOracle).poke();
        for (uint256 i = 0; i < s.debt.length; ++i) {
            // forge-lint: disable-next-line(unused-return)
            if (!s.defs[i].fixedPrice) IDebtOracle(s.defs[i].priceSource).poke();
        }
        _gates(s, borrow);
    }

    /// @inheritdoc IRiskModuleBorrowLogic
    function gate(
        address proxy,
        uint256 debtReserveId,
        bool borrow
    ) external view override {
        _requireSequencerUp();
        _gates(_scope(proxy, debtReserveId, borrow), borrow);
    }

    /// @inheritdoc IRiskModuleBorrowLogic
    function postHealthCheck(
        address proxy,
        uint256 minHealthFactor
    ) external view override returns (uint256 healthFactor) {
        uint256 marketId;
        address lpOracle;
        uint256 served;
        (, healthFactor, served, marketId, lpOracle) = _healthAndPrice(proxy);
        // The accepted price bounds borrowing; the served price is reused if the rescue valuation read it.
        if (served == 0) served = _served(lpOracle);
        healthFactor = RiskModuleMath.boundedHealthFactor(healthFactor, served, _accepted(lpOracle));
        uint256 required = RiskModuleMath.requiredHealthFactor(_store().hardHealthFloor(marketId), minHealthFactor);
        if (healthFactor < required) revert HealthFactorTooLow(healthFactor, required);
    }

    /// @inheritdoc IRiskModuleBorrowLogic
    function healthFactors(
        address proxy
    ) external view override returns (uint256 hf, uint256 hfEx) {
        (hf, hfEx) = _health(proxy);
    }

    /// @inheritdoc IRiskModuleBorrowLogic
    function debtValueUsd(
        address proxy
    ) external view override returns (uint256 usd) {
        (address spoke,) = _account(proxy);
        usd = RiskModuleMath.debtUsd(_accountData(spoke, proxy).totalDebtValueRay);
    }

    /// @dev Aave's health factor less the value of the account's rescue units.
    function _health(
        address proxy
    ) internal view returns (uint256 hf, uint256 hfEx) {
        (hf, hfEx,,,) = _healthAndPrice(proxy);
    }

    function _healthAndPrice(
        address proxy
    ) internal view returns (uint256 hf, uint256 hfEx, uint256 served, uint256 marketId, address lpOracle) {
        address spoke;
        (spoke, marketId) = _account(proxy);
        Market memory m = _market(marketId);
        lpOracle = m.lpOracle;
        IAaveV4Spoke.UserAccountData memory a = _accountData(spoke, proxy);
        hf = a.healthFactor;
        uint256 u = ICollateralizationViews(_COLLATERALIZATION).getAccountRescueUnits(proxy, m.vaultToken);
        if (u == 0) return (hf, hf, 0, marketId, lpOracle);
        IAaveV4Spoke sp = IAaveV4Spoke(spoke);
        uint32 key = sp.getUserPosition(m.reserveId, proxy).dynamicConfigKey;
        uint256 cf = sp.getDynamicReserveConfig(m.reserveId, key).collateralFactor;
        served = _served(lpOracle);
        uint256 e = RiskModuleMath.rescueValue(u, served, cf, m.decimals);
        hfEx = RiskModuleMath.healthExcludingRescue(hf, e, a.totalDebtValueRay);
    }

    function _gates(
        Scope memory s,
        bool borrow
    ) internal view {
        _collateralPrice(s);
        _debtPrices(s);
        IAaveV4Spoke sp = IAaveV4Spoke(s.spoke);
        IAaveV4Spoke.ReserveConfig memory rc = sp.getReserveConfig(s.m.reserveId);
        if (rc.paused) revert AaveReservePaused(s.m.reserveId);
        if (borrow) {
            if (s.m.status == MarketStatus.Offboarding) revert MarketOffboarding(s.marketId);
            if (rc.frozen && sp.getUserSuppliedShares(s.m.reserveId, s.proxy) > 0) revert ReserveFrozen(s.m.reserveId);
        }
        uint256[] memory one = new uint256[](1);
        one[0] = s.marketId;
        (uint256 driftMarket, DriftReason reason) = IRiskModuleDriftLogic(_DRIFT).driftOf(s.spoke, one, s.proxy);
        if (reason != DriftReason.None) revert ConfigDrift(driftMarket, reason);
        if (!IRiskModuleDriftLogic(_DRIFT).isHubSharesEqualAssets(s.marketId)) {
            revert HubSharesNotEqualAssets(s.marketId);
        }
        if (ILPVaultSwapViews(_LP_VAULT_SWAP).activeKeeperCount() == 0) revert LiquidationHalted(s.marketId);
        (bool halted, uint256 haltedReserve) = _routeHalt(s);
        if (halted) revert DebtLiquidationHalted(haltedReserve);
        _breakers(s, borrow);
        if (borrow) _creditLine(s);
    }

    function _collateralPrice(
        Scope memory s
    ) internal view {
        PriceStateView memory pv = ILPOracle(s.m.lpOracle).getPriceState();
        if (pv.state != PriceState.Live) revert PriceNotLive(s.marketId, pv.state);
        for (uint256 i = 0; i < pv.tokens.length; ++i) {
            TokenPriceView memory t = pv.tokens[i];
            for (uint256 j = 0; j < 2; ++j) {
                address feed = t.legFeeds[j];
                if (feed == address(0)) continue;
                uint256 at = t.legUpdatedAt[j];
                if (!PriceAge.borrowFresh(at, _store().borrowPriceMaxAge(feed))) {
                    // forge-lint: disable-next-line(require-revert-in-loop)
                    revert PriceTooOld(feed, PriceAge.age(at));
                }
            }
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (!_tokenSecondSourceConfirmed(t)) revert SecondSourceDisagrees(t.token);
        }
        if (!_marketSecondSourcesConfirmed(pv)) revert SecondSourceDisagrees(address(0));
        if (!pv.borrowAllowed) revert PriceNotLive(s.marketId, pv.state);
    }

    function _tokenSecondSourceConfirmed(
        TokenPriceView memory t
    ) internal pure returns (bool) {
        return t.reasons & TOKEN_SECOND_SOURCE_BITS == 0;
    }

    function _marketSecondSourcesConfirmed(
        PriceStateView memory pv
    ) internal pure returns (bool) {
        return pv.reasons & PRICE_SECOND_SOURCE_BIT == 0;
    }

    function _debtPrices(
        Scope memory s
    ) internal view {
        IAaveV4Spoke sp = IAaveV4Spoke(s.spoke);
        address oracle = sp.ORACLE();
        for (uint256 i = 0; i < s.debt.length; ++i) {
            uint256 r = s.debt[i];
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (sp.getReserveConfig(r).paused) revert DebtReservePaused(r);
            address source = IAaveV4Oracle(oracle).getReserveSource(r);
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (source != s.defs[i].priceSource) revert UnexpectedDebtPriceSource(r, source);
            if (s.defs[i].fixedPrice) continue;
            DebtPriceView memory dv = IDebtOracle(source).getPriceState();
            if (!PriceAge.debtBorrowable(dv, IDebtOracle(source).borrowPriceMaxAge())) {
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert DebtPriceTooOld(r, source, PriceAge.age(dv.servedUpdatedAt));
            }
        }
    }

    /// @dev The market breaker, and the debt breaker of the borrowed reserve or, on a withdrawal, every one held.
    function _breakers(
        Scope memory s,
        bool borrow
    ) internal view {
        IRiskModuleBreakerLogic b = IRiskModuleBreakerLogic(_BREAKER);
        // Any reason blocks the borrow, so the reopening time is not used.
        // forge-lint: disable-next-line(unused-return)
        (uint32 reasons,) = b.marketBreaker(s.marketId, false, 0);
        if (reasons != 0) revert BreakerTripped(s.marketId, reasons);
        for (uint256 i = 0; i < s.debt.length; ++i) {
            uint256 r = s.debt[i];
            if (borrow && r != s.borrowed) continue;
            // Any reason blocks the borrow, so the reopening time is not used.
            // forge-lint: disable-next-line(unused-return)
            (reasons,) = b.debtBreaker(s.spoke, r);
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (reasons != 0) revert DebtBreakerTripped(s.spoke, r, reasons);
        }
    }

    function _creditLine(
        Scope memory s
    ) internal view {
        for (uint256 i = 0; i < s.debt.length; ++i) {
            if (s.debt[i] != s.borrowed) continue;
            address fundingHub = s.defs[i].fundingHub;
            if (fundingHub == s.m.hub) return;
            // A disabled cross-Hub line refuses the whole borrow.
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (!_registry().crossHubLinesEnabled()) revert IMarketRegistryHubs.CrossHubLinesDisabled();
            address asset = s.defs[i].asset;
            (uint256 line, uint256 sum) = _registry().creditLine(fundingHub, asset);
            // A full credit line refuses the whole borrow.
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (sum > line) revert IMarketRegistryCreditLines.CreditLineExceeded(fundingHub, asset, sum, line);
            (uint256 required, uint256 funded) = _registry().creditLineCoverage(fundingHub, asset);
            if (required > funded) {
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert IMarketRegistryCreditLines.CoverageBelowRatio(fundingHub, asset, required, funded);
            }
            return;
        }
    }
}
// forge-lint: disable-end(calls-loop)
