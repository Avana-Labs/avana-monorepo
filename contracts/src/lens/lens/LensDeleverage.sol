// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralization} from "../../custody/collateralization/ICollateralization.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {SettlementMath} from "../../liquidation/lp-vault-swap/SettlementMath.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/MarketRegistryTypes.sol";
import {Market, PauseReason, PauseState} from "../../types/MarketTypes.sol";
import {PriceStateView} from "../../types/OracleTypes.sol";
import {ILensHubReads} from "./ILensHubReads.sol";
import {ILensSpokeReads} from "./ILensSpokeReads.sol";
import {LensAccountMath} from "./LensAccountMath.sol";
import {PriceInput} from "./types/LensTypes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensDeleverage
/// @notice Repay-with-collateral arithmetic shared by its preview and inverse sizing, plus borrow-rate growth.
// Loops over a market's pool tokens and price inputs.
// forge-lint: disable-start(calls-loop)
abstract contract LensDeleverage is LensAccountMath {
    uint256 internal constant RAY_UNIT = 1e27;
    /// @dev Aave's year for rates (`MathUtils.SECONDS_PER_YEAR`).
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    struct Repay {
        Market m;
        DebtReserveDef def;
        address wallet;
        address proxy;
        uint256 marketId;
        bytes32 positionKey;
        uint256 units;
    }

    struct Delev {
        // Prices (collateral the lower, debt the higher of Aave's and the oracle's) and decimals.
        uint256 pc;
        uint256 pd;
        uint8 vaultDecimals;
        uint8 debtDecimals;
        // Sizing terms: slippage allowance, `U`, `ε`, `maxFlashFeeBps`.
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

    /// @dev Whether `repayWithCollateral` would pass; `Paused(General)` and freezes leave it open.
    function _deleverageOpen(
        Repay memory r
    ) internal view returns (bool) {
        if (r.units == 0) return false;
        return r.units <= _deleverageLimit(r);
    }

    /// @dev Most units of the record a repay with collateral can use; 0 when another `_deleverageOpen` check fails.
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
        ICollateralization coll = ICollateralization(_COLLATERALIZATION);
        uint256 id = coll.recordIdOf(m.integrationId, r.positionKey);
        if (id == 0 || coll.getRecord(id).proxy != r.proxy) return 0;
        return coll.previewRelease(m.integrationId, r.positionKey);
    }

    /// @dev Collateral price rule: not liquidation-paused and every input within its `liquidationPriceMaxAge`.
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

    /// @dev `U` in the debt asset: one raw unit's value per pool token, rounded up.
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

    /// @dev Repayment `x = min(debt, deleverageCap(...))` for `units`; `(0, 0)` while a price is 0.
    function _sizeAt(
        Delev memory d,
        uint256 units
    ) internal pure returns (uint256 x, uint256 value) {
        if (d.pc == 0 || d.pd == 0) return (0, 0);
        value = SettlementMath.seizedValue(units, d.pc, d.vaultDecimals, d.debtDecimals, d.pd);
        uint256 cap = SettlementMath.deleverageCap(value, d.slippageBps, d.u, d.eps, d.feeBps);
        x = d.total < cap ? d.total : cap;
    }

    /// @dev Aave's health factor after repaying `x` and withdrawing `units`, at the latest collateral factor.
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
