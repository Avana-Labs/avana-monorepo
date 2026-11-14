// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {SettlementMath} from "../../liquidation/lp-vault-swap/SettlementMath.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/DebtReserveDef.sol";
import {Market} from "../../types/Market.sol";
import {PauseReason} from "../../types/PauseReason.sol";
import {PauseState} from "../../types/PauseState.sol";
import {PriceStateView} from "../../types/PriceStateView.sol";
import {ILensHubReads} from "./ILensHubReads.sol";
import {ILensSpokeReads} from "./ILensSpokeReads.sol";
import {LensAccountMath} from "./LensAccountMath.sol";
import {PriceInput} from "./types/PriceInput.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensDeleverage
/// @notice The repay-with-collateral arithmetic shared by its preview and its inverse sizing: the gates, the repayment
/// `x` of SPEC-LIQ-020 for a number of units, and the account's health factor after, plus the borrow-rate growth the
/// spend-cap quotes use.
/// @dev The inputs are read once (`_deleverageInputs`), so the inverse sizing evaluates `x` and the health factor for
/// many unit counts without further calls. The health factor after follows the Adapter's order (the debt is repaid,
/// then the units are withdrawn, which refreshes the account to the reserve's latest collateral factor) and Aave's
/// repay arithmetic (`LensAccountMath._restRay`).
/// @custom:spec REQ-LENS-038, REQ-LENS-055, SPEC-LIQ-020, REQ-LENS-035, REQ-LENS-036
// View calls in a loop over a market's pool tokens and price inputs (REQ-LENS-020).
// forge-lint: disable-start(calls-loop)
abstract contract LensDeleverage is LensAccountMath {
    /// @dev RAY.
    uint256 internal constant RAY_UNIT = 1e27;
    /// @dev Aave's year for rates (`MathUtils.SECONDS_PER_YEAR`).
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @dev One repay-with-collateral request.
    struct Repay {
        Market m;
        DebtReserveDef def;
        address wallet;
        address proxy;
        uint256 marketId;
        bytes32 positionKey;
        uint256 units;
    }

    /// @dev The reads a repay with collateral is sized from, for any number of units.
    struct Delev {
        // SPEC-LIQ-004 prices (collateral the lower, debt the higher of Aave's and the oracle's) and decimals.
        uint256 pc;
        uint256 pd;
        uint8 vaultDecimals;
        uint8 debtDecimals;
        // SPEC-LIQ-020 terms: slippage allowance, `U`, `ε`, `maxFlashFeeBps`.
        uint256 slippageBps;
        uint256 u;
        uint256 eps;
        uint256 feeBps;
        // The account's debt on the reserve, base units.
        uint256 total;
        // Aave's view: vault-token assets, served value per unit, latest collateral factor.
        uint256 assets;
        uint256 unitValue;
        uint256 cf;
        // The account's debt value without the reserve, and the reserve's drawn shares, premium (RAY) and index.
        uint256 otherDebtRay;
        uint256 drawnShares;
        uint256 premiumRay;
        uint256 index;
        uint256 debtUnitValue;
    }

    /// @dev The account's borrow rate on a reserve: the drawn rate plus its risk-premium share, RAY per year.
    /// @custom:spec REQ-LENS-035, REQ-LENS-036
    function _rate(
        DebtReserveDef memory def,
        uint256 riskPremium
    ) internal view returns (uint256) {
        uint256 drawn = ILensHubReads(def.fundingHub).getAssetDrawnRate(def.hubAssetId);
        return Math.mulDiv(drawn, SettlementMath.BPS + riskPremium, SettlementMath.BPS, Math.Rounding.Ceil);
    }

    /// @dev `RAY × (1 + rate × max(0, deadline − now))`, the interest growth until `deadline`, rounded up.
    function _growth(
        uint256 rate,
        uint256 deadline
    ) internal view returns (uint256) {
        uint256 dt = deadline > block.timestamp ? deadline - block.timestamp : 0;
        return RAY_UNIT + Math.mulDiv(rate, dt, SECONDS_PER_YEAR, Math.Rounding.Ceil);
    }

    /// @dev Whether `repayWithCollateral` would pass its checks: liquidation-grade prices on the market and the debt
    /// reserve, Hub shares equal to assets, the Hub not `Paused(MintPathSuspect)`, the record is the account's and `units`
    /// is within its credited units after reconciliation, and the account owes on the reserve. `Paused(General)`, Frozen
    /// and a frozen wallet leave it open, as at the Adapter, because it only reduces debt (REQ-ADAPTER-080, Q-356).
    /// @custom:spec REQ-LENS-038, SPEC-LIQ-020, REQ-ADAPTER-080, REQ-ADAPTER-082
    function _deleverageOpen(
        Repay memory r
    ) internal view returns (bool) {
        if (r.units == 0) return false;
        return r.units <= _deleverageLimit(r);
    }

    /// @dev The most units of the record a repay with collateral can use: its credited units after reconciliation, or 0
    /// when any other check of `_deleverageOpen` fails.
    /// @custom:spec REQ-LENS-038, REQ-LENS-055
    function _deleverageLimit(
        Repay memory r
    ) internal view returns (uint256) {
        Market memory m = r.m;
        if (IAaveV4Spoke(m.spoke).getUserTotalDebt(r.def.reserveId, r.proxy) == 0) return 0;
        if (_registry().pauseState(m.hub) == PauseState.Paused) {
            if (_registry().pauseReason(m.hub) == PauseReason.MintPathSuspect) return 0;
        }
        IAaveV4Hub hub = IAaveV4Hub(m.hub);
        if (hub.getAddedAssets(m.hubAssetId) != hub.getAddedShares(m.hubAssetId)) return 0;
        if (!_marketPriceUsable(m) || !_debtView(m.spoke, r.def).liquidationFresh) return 0;
        ICollateralizationViews coll = ICollateralizationViews(_COLLATERALIZATION);
        uint256 id = coll.recordIdOf(m.integrationId, r.positionKey);
        if (id == 0 || coll.getRecord(id).proxy != r.proxy) return 0;
        return coll.previewRelease(m.integrationId, r.positionKey);
    }

    /// @dev The market's collateral price rule (REQ-SWAP-008): not liquidation-paused and every input within its
    /// `liquidationPriceMaxAge`.
    function _marketPriceUsable(
        Market memory m
    ) internal view returns (bool) {
        PriceStateView memory ps = ILPOracle(m.lpOracle).getPriceState();
        if (ps.liquidationPaused) return false;
        PriceInput[] memory inputs = _inputs(ps.tokens);
        for (uint256 i = 0; i < inputs.length; ++i) {
            if (!inputs[i].liquidationFresh) return false;
        }
        return true;
    }

    /// @dev Reads every input of the sizing once.
    /// @custom:spec SPEC-LIQ-020, SPEC-LIQ-004, REQ-LENS-055
    function _deleverageInputs(
        Repay memory r
    ) internal view returns (Delev memory d) {
        Market memory m = r.m;
        (d.vaultDecimals, d.debtDecimals) = (m.decimals, r.def.decimals);
        (d.pc, d.pd) = (_collateralPrice(m), _debtPrice(m.spoke, r.def));
        if (d.pd != 0) d.u = _unwindAllowance(m, r.def, d.pd);
        d.slippageBps = _store().getMarketParams(r.marketId).slippageAllowanceBps;
        (d.eps, d.feeBps) = (_store().floorRoundingAllowance(r.def.asset), _store().maxFlashFeeBps());
        IAaveV4Spoke spoke = IAaveV4Spoke(m.spoke);
        d.total = spoke.getUserTotalDebt(r.def.reserveId, r.proxy);
        (d.assets, d.unitValue, d.cf) = (_assetsOf(m, r.proxy), _servedPrice(m) * 10 ** (18 - m.decimals), _latestCf(m));
        d.index = ILensHubReads(r.def.fundingHub).getAssetDrawnIndex(r.def.hubAssetId);
        d.drawnShares = spoke.getUserPosition(r.def.reserveId, r.proxy).drawnShares;
        d.premiumRay = ILensSpokeReads(m.spoke).getUserPremiumDebtRay(r.def.reserveId, r.proxy);
        d.debtUnitValue = IAaveV4Oracle(spoke.ORACLE()).getReservePrice(r.def.reserveId) * 10 ** (18 - r.def.decimals);
        uint256 own = (d.drawnShares * d.index + d.premiumRay) * d.debtUnitValue;
        uint256 all = spoke.getUserAccountData(r.proxy).totalDebtValueRay;
        d.otherDebtRay = all > own ? all - own : 0;
    }

    /// @dev `U` of SPEC-LIQ-005 in the debt asset: one base unit per pool token that is the debt asset, the value of one
    /// raw unit (rounded up) for every other priced token.
    function _unwindAllowance(
        Market memory m,
        DebtReserveDef memory def,
        uint256 pd
    ) internal view returns (uint256 u) {
        // forge-lint: disable-next-line(unused-return)
        (uint256[] memory prices,,) = ILPOracle(m.lpOracle).getTokenPrices();
        for (uint256 i = 0; i < m.tokens.length; ++i) {
            if (m.tokens[i] == def.asset) ++u;
            else if (prices[i] != 0) u += _tokenValue(1, prices[i], m.tokenDecimals[i], def.decimals, pd, true);
        }
    }

    /// @dev SPEC-LIQ-020 for `units`: `V`, `cap = deleverageCap(V, s, U, ε, maxFlashFeeBps)` and `x = min(debt, cap)`;
    /// `(0, 0)` while a price is 0.
    /// @custom:spec SPEC-LIQ-020, SPEC-LIQ-004
    function _sizeAt(
        Delev memory d,
        uint256 units
    ) internal pure returns (uint256 x, uint256 value) {
        if (d.pc == 0 || d.pd == 0) return (0, 0);
        value = SettlementMath.seizedValue(units, d.pc, d.vaultDecimals, d.debtDecimals, d.pd);
        uint256 cap = SettlementMath.deleverageCap(value, d.slippageBps, d.u, d.eps, d.feeBps);
        x = d.total < cap ? d.total : cap;
    }

    /// @dev Aave's health factor after repaying `x` and withdrawing `units`: the reserve's debt follows Aave's repay
    /// (`_restRay`), the collateral is `assets − units` at the served price and the latest collateral factor.
    /// @custom:spec REQ-LENS-038, REQ-LENS-055
    function _healthAt(
        Delev memory d,
        uint256 units,
        uint256 x
    ) internal pure returns (uint256) {
        uint256 debtRay = d.otherDebtRay + _restRay(d.drawnShares, d.premiumRay, d.index, x) * d.debtUnitValue;
        uint256 assets = d.assets > units ? d.assets - units : 0;
        return _hfOf(d.cf, assets * d.unitValue, debtRay);
    }
}
// forge-lint: disable-end(calls-loop)
