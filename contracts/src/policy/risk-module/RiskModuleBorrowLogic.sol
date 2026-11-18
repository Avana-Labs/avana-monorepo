// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralization} from "../../custody/collateralization/ICollateralization.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwap} from "../../liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {ChainlinkPrice} from "../../oracle/ChainlinkPrice.sol";
import {ILPOracle} from "../../oracle/ILPOracle.sol";
import {LPPriceMath} from "../../oracle/LPPriceMath.sol";
import {DriftReason, Market} from "../../types/MarketTypes.sol";
import {IMarketRegistry} from "../market-registry/IMarketRegistry.sol";
import {MarketStatus} from "../market-registry/types/MarketRegistryTypes.sol";
import {IRiskModuleBorrowLogic} from "./IRiskModuleBorrowLogic.sol";
import {IRiskModuleBreakerLogic} from "./IRiskModuleBreakerLogic.sol";
import {IRiskModuleDriftLogic} from "./IRiskModuleDriftLogic.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";
import {RiskModuleBorrowScope} from "./RiskModuleBorrowScope.sol";
import {RiskModuleMath} from "./RiskModuleMath.sol";
import {RiskModuleImmutables} from "./types/RiskModuleTypes.sol";

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
        _gates(_scope(proxy, debtReserveId, borrow), borrow);
    }

    /// @inheritdoc IRiskModuleBorrowLogic
    function gate(
        address proxy,
        uint256 debtReserveId,
        bool borrow
    ) external view override {
        _gates(_scope(proxy, debtReserveId, borrow), borrow);
    }

    /// @inheritdoc IRiskModuleBorrowLogic
    function postHealthCheck(
        address proxy,
        uint256 minHealthFactor
    ) external view override returns (uint256 healthFactor) {
        // Only the health factor is used here.
        // forge-lint: disable-next-line(unused-return)
        (, healthFactor,,,) = _healthAndPrice(proxy);
        uint256 required = RiskModuleMath.requiredHealthFactor(minHealthFactor);
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
        uint256 u = ICollateralization(_COLLATERALIZATION).getAccountRescueUnits(proxy, m.vaultToken);
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
        if (ILPVaultSwap(_LP_VAULT_SWAP).activeKeeperCount() == 0) revert LiquidationHalted(s.marketId);
        (bool halted, uint256 haltedReserve) = _routeHalt(s);
        if (halted) revert DebtLiquidationHalted(haltedReserve);
        _breakers(s, borrow);
        if (borrow) _coverage(s);
    }

    function _collateralPrice(
        Scope memory s
    ) internal view {
        ILPOracle.PriceStatus memory st = ILPOracle(s.m.lpOracle).getPriceStatus();
        if (!st.borrowFresh) revert PriceTooOld(s.m.lpOracle, LPPriceMath.age(st.updatedAt));
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
            ChainlinkPrice.Reading memory p = ChainlinkPrice.read(source, address(_store()));
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (!p.borrowFresh) revert DebtPriceTooOld(r, source, LPPriceMath.age(p.updatedAt));
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
        (uint32 reasons,) = b.marketBreaker(s.marketId);
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

    /// @dev The First-Loss Reserve of the borrowed asset covers the summed Aave draw caps of its Spokes; a draw-cap
    /// raise past the cover refuses new borrows of the asset until the reserve is funded or the cap is cut.
    function _coverage(
        Scope memory s
    ) internal view {
        for (uint256 i = 0; i < s.debt.length; ++i) {
            if (s.debt[i] != s.borrowed) continue;
            (address hub, address asset) = (s.defs[i].fundingHub, s.defs[i].asset);
            // forge-lint: disable-next-line(unused-return)
            (, uint256 required, uint256 funded) = _registry().drawCapCoverage(hub, asset);
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (required > funded) revert IMarketRegistry.CoverageBelowRatio(hub, asset, required, funded);
            return;
        }
    }
}
// forge-lint: disable-end(calls-loop)
