// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/DebtReserveDef.sol";
import {Market} from "../../types/Market.sol";
import {ILensActions} from "./ILensActions.sol";
import {ILensHubReads} from "./ILensHubReads.sol";
import {ILensSpokeReads} from "./ILensSpokeReads.sol";
import {LensAccountMath} from "./LensAccountMath.sol";
import {ActionPreview} from "./types/ActionPreview.sol";

/// @title LensActions
/// @notice Health factor and liquidation price before and after a borrow, a repay, a pledge or a withdrawal.
/// @dev Each preview applies the action to the account's Aave state as the Spoke and Hub would at this block: a borrow
/// adds `previewDrawByAssets` drawn shares (rounded up), a repay follows `UserPositionUtils.calculateRestoreAmount`
/// (premium first, drawn shares restored rounded down), a pledge and a withdrawal move the account's vault-token assets
/// by the units credited or withdrawn. The collateral factor after is the one Aave applies: the reserve's latest after a
/// borrow or a withdrawal (both refresh the account's dynamic configuration) and after a pledge that enables the
/// collateral, the account's own otherwise.
/// @custom:spec REQ-LENS-052, REQ-LENS-053
abstract contract LensActions is LensAccountMath, ILensActions {
    /// @dev One account's starting state.
    struct Acct {
        Market m;
        address proxy;
        // Vault-token assets Aave counts as collateral (0 while the collateral flag is off).
        uint256 assets;
        // Vault-token assets on the Hub, counted or not.
        uint256 held;
        bool enabled;
        uint256 debtRay;
    }

    /// @inheritdoc ILensActions
    /// @custom:spec REQ-LENS-052, REQ-LENS-005, REQ-LENS-006, REQ-LENS-032
    function previewBorrowAfter(
        address wallet,
        uint256 marketId,
        uint256 debtReserveId,
        uint256 amount
    ) external view override returns (ActionPreview memory v) {
        _unlocked();
        Acct memory a;
        (a, v) = _start(wallet, marketId);
        DebtReserveDef memory def = _debtReserve(a.m.spoke, debtReserveId);
        ILensHubReads hub = ILensHubReads(def.fundingHub);
        uint256 shares = hub.previewDrawByAssets(def.hubAssetId, amount);
        uint256 added = _debtValueRay(a.m, def, shares * hub.getAssetDrawnIndex(def.hubAssetId));
        v.amount = amount;
        _finish(a, v, _latestCf(a.m), a.assets, a.debtRay + added);
    }

    /// @inheritdoc ILensActions
    /// @custom:spec REQ-LENS-052, REQ-LENS-005, REQ-LENS-006, REQ-LENS-032
    function previewRepayAfter(
        address wallet,
        uint256 marketId,
        uint256 debtReserveId,
        uint256 amount
    ) external view override returns (ActionPreview memory v) {
        _unlocked();
        Acct memory a;
        (a, v) = _start(wallet, marketId);
        DebtReserveDef memory def = _debtReserve(a.m.spoke, debtReserveId);
        uint256 total = IAaveV4Spoke(a.m.spoke).getUserTotalDebt(debtReserveId, a.proxy);
        v.amount = amount < total ? amount : total;
        _finish(a, v, _cf(a.m, a.proxy), a.assets, _debtAfterRepay(a, def, amount));
    }

    /// @inheritdoc ILensActions
    /// @custom:spec REQ-LENS-053, REQ-LENS-005, REQ-LENS-006
    function previewPledgeAfter(
        address wallet,
        uint256 marketId,
        bytes32 positionKey
    ) external view override returns (ActionPreview memory v) {
        _unlocked();
        Acct memory a;
        (a, v) = _start(wallet, marketId);
        v.amount = IAmmIntegration(a.m.integration).validatePosition(marketId, wallet, positionKey);
        // A pledge that turns the collateral on refreshes the account's dynamic configuration (`setUsingAsCollateral`).
        uint256 cf = a.enabled ? _cf(a.m, a.proxy) : _latestCf(a.m);
        _finish(a, v, cf, a.held + v.amount, a.debtRay);
    }

    /// @inheritdoc ILensActions
    /// @custom:spec REQ-LENS-053, REQ-LENS-005, REQ-LENS-006
    function previewWithdrawAfter(
        address wallet,
        uint256 marketId,
        bytes32 positionKey
    ) external view override returns (ActionPreview memory v) {
        _unlocked();
        Acct memory a;
        (a, v) = _start(wallet, marketId);
        ICollateralizationViews coll = ICollateralizationViews(_COLLATERALIZATION);
        uint256 id = coll.recordIdOf(a.m.integrationId, positionKey);
        if (id != 0 && coll.getRecord(id).proxy == a.proxy) {
            v.amount = coll.previewRelease(a.m.integrationId, positionKey);
        }
        uint256 cf = v.amount > 0 && a.enabled ? _latestCf(a.m) : _cf(a.m, a.proxy);
        _finish(a, v, cf, a.assets > v.amount ? a.assets - v.amount : 0, a.debtRay);
    }

    // ------------------------------------------------------------------------------------------------------ internal

    /// @dev The account's starting state and the `before` half of the preview.
    function _start(
        address wallet,
        uint256 marketId
    ) internal view returns (Acct memory a, ActionPreview memory v) {
        a.m = _market(marketId);
        (a.proxy,) = _proxy(wallet, marketId, a.m.spoke);
        (v.blockNumber, v.timestamp, v.proxy) = (block.number, block.timestamp, a.proxy);
        IAaveV4Spoke.UserAccountData memory d = IAaveV4Spoke(a.m.spoke).getUserAccountData(a.proxy);
        // forge-lint: disable-next-line(unused-return)
        (a.enabled,) = IAaveV4Spoke(a.m.spoke).getUserReserveStatus(a.m.reserveId, a.proxy);
        a.held = _assetsOf(a.m, a.proxy);
        a.assets = a.enabled ? a.held : 0;
        a.debtRay = d.totalDebtValueRay;
        v.healthFactorBefore = d.healthFactor;
        v.liquidationPriceBefore =
            _liquidationPrice(a.debtRay, _cf(a.m, a.proxy) * a.assets * 10 ** (18 - a.m.decimals));
    }

    /// @dev Fills the `after` half from the collateral factor, assets and debt value after the action.
    function _finish(
        Acct memory a,
        ActionPreview memory v,
        uint256 cf,
        uint256 assets,
        uint256 debtRay
    ) internal view {
        uint256 scale = 10 ** (18 - a.m.decimals);
        v.collateralValueAfter = assets * _servedPrice(a.m) * scale;
        v.debtValueAfterRay = debtRay;
        v.healthFactorAfter = _hfOf(cf, v.collateralValueAfter, debtRay);
        v.liquidationPriceAfter = _liquidationPrice(debtRay, cf * assets * scale);
    }

    /// @dev The account's debt value (Aave value × RAY) after repaying `amount` of the reserve: its other debts plus the
    /// reserve's debt left by `_restRay`, both valued as `Spoke._processUserAccountData` values them.
    /// @custom:spec REQ-LENS-052
    function _debtAfterRepay(
        Acct memory a,
        DebtReserveDef memory def,
        uint256 amount
    ) internal view returns (uint256) {
        uint256 index = ILensHubReads(def.fundingHub).getAssetDrawnIndex(def.hubAssetId);
        uint256 drawnShares = IAaveV4Spoke(a.m.spoke).getUserPosition(def.reserveId, a.proxy).drawnShares;
        uint256 premiumRay = ILensSpokeReads(a.m.spoke).getUserPremiumDebtRay(def.reserveId, a.proxy);
        uint256 before = _debtValueRay(a.m, def, drawnShares * index + premiumRay);
        return a.debtRay - before + _debtValueRay(a.m, def, _restRay(drawnShares, premiumRay, index, amount));
    }

    /// @dev Aave's value of a debt in asset units × RAY: `debtRay × price × 10^(18 − decimals)` at the served price.
    function _debtValueRay(
        Market memory m,
        DebtReserveDef memory def,
        uint256 assetRay
    ) internal view returns (uint256) {
        uint256 price = IAaveV4Oracle(IAaveV4Spoke(m.spoke).ORACLE()).getReservePrice(def.reserveId);
        return assetRay * price * 10 ** (18 - def.decimals);
    }
}
