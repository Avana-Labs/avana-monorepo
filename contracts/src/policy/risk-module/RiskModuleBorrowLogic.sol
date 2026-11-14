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
/// @notice Bodies of `preBorrowCheck`, `preWithdrawCheck`, `postHealthCheck` and `debtValueUsd`, and the same gates as a
/// view for the account status.
/// @dev Order (2.7 Borrow-side checks): (0) sequencer gate; (1) approved Spoke; (2) scope from the Spoke; (3) collateral
/// mapping and debt-reserve definitions; (4) pokes of the market's LPOracle and of the DebtOracle of every debt reserve
/// priced by one; (5) collateral price state, per-feed ages and second sources; (6) debt-reserve pauses, sources and
/// prices; (7) collateral reserve pause; (8) borrow only: Offboarding and the frozen reserve; (9) drift; (10) Hub shares
/// == assets; (11) liquidation halts; (12) the market breaker and the debt breakers; (13) borrow only: the cross-Hub
/// credit line and its coverage. The pokes are the only state-changing calls (REQ-RISK-003); their reverts propagate
/// (REQ-RISK-056).
/// @custom:spec REQ-ADAPTER-009, REQ-ADAPTER-010, REQ-ADAPTER-011, REQ-ADAPTER-012, REQ-ADAPTER-013, REQ-ADAPTER-014, REQ-ADAPTER-015, REQ-ADAPTER-016, REQ-ADAPTER-018, REQ-ADAPTER-019, REQ-ADAPTER-020, REQ-ADAPTER-021, REQ-ADAPTER-022, REQ-ADAPTER-023, REQ-ADAPTER-024, REQ-ADAPTER-025, REQ-ADAPTER-026, REQ-ADAPTER-027, REQ-ADAPTER-061, REQ-RISK-056, REQ-RISK-059, REQ-RISK-061, REQ-RISK-062, REQ-RISK-065, REQ-RISK-068, REQ-RISK-071, REQ-RISK-077, REQ-RISK-081, REQ-RISK-082, SPEC-CF-005, SPEC-CAP-009
// View calls in loops over the account's reserves and the market's tokens, bounded by listings.
// forge-lint: disable-start(calls-loop)
contract RiskModuleBorrowLogic is RiskModuleBorrowScope, IRiskModuleBorrowLogic {
    /// @notice Fixes the implementation immutables and the drift and breaker logic.
    /// @param im The per-chain Avana addresses.
    /// @param drift The drift logic built with `im`.
    /// @param breaker The breaker logic built with `im`.
    /// @custom:spec REQ-RISK-002
    constructor(
        RiskModuleImmutables memory im,
        address drift,
        address breaker
    ) RiskModuleBorrowScope(im, drift, breaker) {}

    /// @inheritdoc IRiskModuleLogic
    /// @custom:spec REQ-RISK-002
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("RiskModuleBorrowLogic"), _IMMUTABLES_HASH);
    }

    /// @inheritdoc IRiskModuleBorrowLogic
    /// @custom:spec REQ-RISK-056, REQ-ADAPTER-024, REQ-ADAPTER-025
    function preCheck(
        address proxy,
        uint256 debtReserveId,
        bool borrow
    ) external override {
        _requireSequencerUp();
        Scope memory s = _scope(proxy, debtReserveId, borrow);
        // The pokes store first observations only (Q-199); the gates read the price state themselves.
        // forge-lint: disable-next-line(unused-return)
        ILPOracle(s.m.lpOracle).poke();
        for (uint256 i = 0; i < s.debt.length; ++i) {
            // forge-lint: disable-next-line(unused-return)
            if (!s.defs[i].fixedPrice) IDebtOracle(s.defs[i].priceSource).poke();
        }
        _gates(s, borrow);
    }

    /// @inheritdoc IRiskModuleBorrowLogic
    /// @custom:spec REQ-RISK-060, REQ-ADAPTER-038
    function gate(
        address proxy,
        uint256 debtReserveId,
        bool borrow
    ) external view override {
        _requireSequencerUp();
        _gates(_scope(proxy, debtReserveId, borrow), borrow);
    }

    /// @inheritdoc IRiskModuleBorrowLogic
    /// @custom:spec REQ-ADAPTER-026, REQ-ADAPTER-027, REQ-RISK-059, REQ-RISK-068, SPEC-CF-005
    function postHealthCheck(
        address proxy,
        uint256 minHealthFactor
    ) external view override returns (uint256 healthFactor) {
        uint256 marketId;
        address lpOracle;
        uint256 served;
        (, healthFactor, served, marketId, lpOracle) = _healthAndPrice(proxy);
        // The accepted price bounds borrowing (SPEC-ORC-017): the check runs at min(served, accepted). The served
        // price is read once, by the rescue-unit valuation when the account has rescue units.
        if (served == 0) served = _served(lpOracle);
        healthFactor = RiskModuleMath.boundedHealthFactor(healthFactor, served, _accepted(lpOracle));
        uint256 required = RiskModuleMath.requiredHealthFactor(_store().hardHealthFloor(marketId), minHealthFactor);
        if (healthFactor < required) revert HealthFactorTooLow(healthFactor, required);
    }

    /// @inheritdoc IRiskModuleBorrowLogic
    /// @custom:spec SPEC-CF-005
    function healthFactors(
        address proxy
    ) external view override returns (uint256 hf, uint256 hfEx) {
        (hf, hfEx) = _health(proxy);
    }

    /// @inheritdoc IRiskModuleBorrowLogic
    /// @custom:spec SPEC-CAP-009, REQ-RISK-077
    function debtValueUsd(
        address proxy
    ) external view override returns (uint256 usd) {
        (address spoke,) = _account(proxy);
        usd = RiskModuleMath.debtUsd(_accountData(spoke, proxy).totalDebtValueRay);
    }

    /// @dev SPEC-CF-005: Aave's health factor less the value of the account's rescue units at the served price and the
    /// account's own dynamic-key collateral factor.
    function _health(
        address proxy
    ) internal view returns (uint256 hf, uint256 hfEx) {
        (hf, hfEx,,,) = _healthAndPrice(proxy);
    }

    /// @dev `_health`, with the served price it read (0 when the account has no rescue units, so none was read), the
    /// account's market and that market's LPOracle.
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

    /// @dev Steps (5) to (13).
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

    /// @dev Step (5): Live, every leg of every token within `borrowPriceMaxAge(feed)` and not in the future, every
    /// token's second source confirmed and the market's second-source flag clear, and the LPOracle's own borrow gate
    /// (sequencer ready, served age).
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
                // forge-lint: disable-next-line(require-revert-in-loop)
                if (!PriceAge.borrowFresh(at, _store().borrowPriceMaxAge(feed))) {
                    revert PriceTooOld(feed, PriceAge.age(at));
                }
            }
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (!_tokenSecondSourceConfirmed(t)) revert SecondSourceDisagrees(t.token);
        }
        if (!_marketSecondSourcesConfirmed(pv)) revert SecondSourceDisagrees(address(0));
        if (!pv.borrowAllowed) revert PriceNotLive(s.marketId, pv.state);
    }

    /// @dev The LPOracle's second-source confirmation of one token (REQ-ORACLE-100): neither SECOND_SOURCE_DISAGREE
    /// (token bit 4) nor SECOND_SOURCE_UNAVAILABLE (token bit 5, an out-of-range configuration word included). The
    /// RiskModule enforces it itself on every borrow and withdraw-with-debt, whatever the oracle's `borrowAllowed`.
    function _tokenSecondSourceConfirmed(
        TokenPriceView memory t
    ) internal pure returns (bool) {
        return t.reasons & TOKEN_SECOND_SOURCE_BITS == 0;
    }

    /// @dev The LPOracle's market-level second-source flag (market bit 16) clear (REQ-ORACLE-100).
    function _marketSecondSourcesConfirmed(
        PriceStateView memory pv
    ) internal pure returns (bool) {
        return pv.reasons & PRICE_SECOND_SOURCE_BIT == 0;
    }

    /// @dev Step (6) for every debt reserve in scope (REQ-RISK-061).
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

    /// @dev Step (12): the market breaker of the account's market and the debt breaker of the borrowed reserve (borrow)
    /// or of every debt reserve held (withdraw-with-debt).
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

    /// @dev Step (13), REQ-RISK-082: a reserve funded by another Hub than the market's needs cross-Hub lines on, the
    /// registry's draw-cap sum within the funding Hub's line, and the line covered by its First-Loss Reserve
    /// (`creditLineCoverage`: `required <= funded`).
    function _creditLine(
        Scope memory s
    ) internal view {
        for (uint256 i = 0; i < s.debt.length; ++i) {
            if (s.debt[i] != s.borrowed) continue;
            address fundingHub = s.defs[i].fundingHub;
            if (fundingHub == s.m.hub) return;
            // A disabled cross-Hub line refuses the whole borrow (REQ-RISK-082).
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (!_registry().crossHubLinesEnabled()) revert IMarketRegistryHubs.CrossHubLinesDisabled();
            address asset = s.defs[i].asset;
            (uint256 line, uint256 sum) = _registry().creditLine(fundingHub, asset);
            // A full credit line refuses the whole borrow (REQ-RISK-082).
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (sum > line) revert IMarketRegistryCreditLines.CreditLineExceeded(fundingHub, asset, sum, line);
            (uint256 required, uint256 funded) = _registry().creditLineCoverage(fundingHub, asset);
            // An uncovered credit line refuses the whole borrow (REQ-RISK-082).
            if (required > funded) {
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert IMarketRegistryCreditLines.CoverageBelowRatio(fundingHub, asset, required, funded);
            }
            return;
        }
    }
}
// forge-lint: disable-end(calls-loop)
