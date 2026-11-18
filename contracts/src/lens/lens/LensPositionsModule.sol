// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralization} from "../../custody/collateralization/ICollateralization.sol";
import {ILPVault} from "../../custody/lp-vault/ILPVault.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/MarketRegistryTypes.sol";
import {IRiskModule} from "../../policy/risk-module/IRiskModule.sol";
import {AccountGateStatus, Market, PauseState} from "../../types/MarketTypes.sol";
import {ILensActions} from "./ILensActions.sol";
import {ILensHubReads} from "./ILensHubReads.sol";
import {ILensPositions} from "./ILensPositions.sol";
import {ILensSpokeReads} from "./ILensSpokeReads.sol";
import {LensAccountMath} from "./LensAccountMath.sol";
import {LensBase} from "./LensBase.sol";
import {
    AccountRiskView,
    ActionPreview,
    PledgePreviewView,
    RecordRemoval,
    RemovalSizing,
    WithdrawPreview
} from "./types/LensTypes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensPositionsModule
/// @notice Lens module serving `ILensPositions`, `ILensActions` and `previewMaxWithdraw`.
contract LensPositionsModule is ILensPositions, ILensActions, LensAccountMath {
    // forge-lint: disable-start(calls-loop)
    function previewMaxWithdraw(
        address wallet,
        uint256 marketId,
        uint256 targetHealthFactor
    ) external view returns (RemovalSizing memory v) {
        _unlocked();
        Market memory m = _market(marketId);
        bool deployed;
        (v.proxy, deployed) = _proxy(wallet, marketId, m.spoke);
        (v.blockNumber, v.timestamp, v.target, v.bestIndex) =
        (block.number, block.timestamp, targetHealthFactor, type(uint256).max);
        if (!deployed) return v;
        v.records = _removals(m, v.proxy);
        uint256 debtRay = IAaveV4Spoke(m.spoke).getUserAccountData(v.proxy).totalDebtValueRay;
        if (debtRay == 0) {
            for (uint256 i = 0; i < v.records.length; ++i) {
                v.maxUnits += v.records[i].units;
            }
        } else {
            uint256 h0 = _store().hardHealthFloor(marketId);
            if (h0 < WAD_) h0 = WAD_;
            if (v.target < h0) v.target = h0;
            if (_withdrawWithDebtOpen(wallet, v.proxy)) v.maxUnits = _maxRemoval(m, v.proxy, v.target, debtRay);
        }
        uint256 best = 0;
        for (uint256 i = 0; i < v.records.length; ++i) {
            RecordRemoval memory r = v.records[i];
            r.fits = r.units > 0 && r.units <= v.maxUnits;
            if (r.fits && r.units > best) (best, v.bestIndex) = (r.units, i);
        }
    }

    /// @dev The AaveAdapter's withdraw-with-debt gates: RiskModule allows it, Hub not `Paused`, wallet not frozen.
    function _withdrawWithDebtOpen(
        address wallet,
        address proxy
    ) internal view returns (bool) {
        AccountGateStatus memory st = IRiskModule(_RISK_MODULE).getAccountGateStatus(proxy);
        return st.withdrawWithDebtAllowed && st.pauseState != PauseState.Paused && !_registry().isFrozenAddress(wallet);
    }

    /// @dev Largest `u ≤ assets` with `W − E − ⌈u × v × CF / 10⁴⌉ ≥ need`, at the reserve's latest collateral factor.
    function _maxRemoval(
        Market memory m,
        address proxy,
        uint256 target,
        uint256 debtRay
    ) internal view returns (uint256 units) {
        uint256 cf = _latestCf(m);
        uint256 per = _servedPrice(m) * 10 ** (18 - m.decimals) * cf;
        // forge-lint: disable-next-line(unused-return)
        (bool enabled,) = IAaveV4Spoke(m.spoke).getUserReserveStatus(m.reserveId, proxy);
        uint256 assets = enabled ? _assetsOf(m, proxy) : 0;
        if (per == 0 || assets == 0) return 0;
        uint256 need = Math.mulDiv(target, debtRay, WAD_ * RAY_, Math.Rounding.Ceil);
        units = _removalBound(assets, per, _rescueAt(m, proxy, cf), need);
    }

    /// @dev Never exceeds `assets`, since `W × 10⁴ ≤ assets × per`; 0 when `W < E + need` or `per = 0`.
    function _removalBound(
        uint256 assets,
        uint256 per,
        uint256 e,
        uint256 need
    ) internal pure returns (uint256 units) {
        if (per == 0) return 0;
        uint256 w = assets * per / 1e4;
        if (w < e || w - e < need) return 0;
        units = (w - e - need) * 1e4 / per;
    }

    // forge-lint: disable-end(calls-loop)

    // forge-lint: disable-start(calls-loop)
    /// @inheritdoc ILensPositions
    function getAccountRisk(
        address wallet,
        uint256 marketId
    ) external view override returns (AccountRiskView memory v) {
        _unlocked();
        Market memory m = _market(marketId);
        (v.blockNumber, v.timestamp) = (block.number, block.timestamp);
        (v.proxy,) = _proxy(wallet, marketId, m.spoke);
        IAaveV4Spoke.UserAccountData memory a = IAaveV4Spoke(m.spoke).getUserAccountData(v.proxy);
        v.reserveIds = _registry().getDebtReserveIds(m.spoke);
        v.borrowRatesRay = new uint256[](v.reserveIds.length);
        for (uint256 i = 0; i < v.reserveIds.length; ++i) {
            DebtReserveDef memory def = _registry().getDebtReserve(m.spoke, v.reserveIds[i]);
            uint256 drawn = ILensHubReads(def.fundingHub).getAssetDrawnRate(def.hubAssetId);
            v.borrowRatesRay[i] = Math.mulDiv(drawn, 1e4 + a.riskPremium, 1e4, Math.Rounding.Ceil);
        }
        if (a.totalDebtValueRay == 0) return v;
        uint256 cfAssets = _cfAssets(m, v.proxy);
        if (cfAssets == 0) {
            v.liquidationPrice = type(uint256).max;
        } else {
            v.liquidationPrice = Math.mulDiv(a.totalDebtValueRay, 1e4, cfAssets * RAY_, Math.Rounding.Ceil);
        }
    }

    /// @inheritdoc ILensPositions
    function previewPledge(
        address depositor,
        uint256 marketId,
        bytes32 positionKey
    ) external view override returns (PledgePreviewView memory v) {
        _unlocked();
        (v.blockNumber, v.timestamp) = (block.number, block.timestamp);
        v.preview = IRiskModule(_RISK_MODULE).previewPledge(depositor, marketId, positionKey);
    }

    /// @inheritdoc ILensPositions
    function previewWithdraw(
        address wallet,
        uint256 marketId,
        bytes32 positionKey,
        uint256 units
    ) external view override returns (WithdrawPreview memory v) {
        _unlocked();
        Market memory m = _market(marketId);
        (v.blockNumber, v.timestamp) = (block.number, block.timestamp);
        (address proxy,) = _proxy(wallet, marketId, m.spoke);
        ICollateralization coll = ICollateralization(_COLLATERALIZATION);
        uint256 id = coll.recordIdOf(m.integrationId, positionKey);
        bool own = id != 0 && coll.getRecord(id).proxy == proxy;
        uint256 limit = own ? coll.previewRelease(m.integrationId, positionKey) : 0;
        v.units = units;
        if (units == 0) v.units = limit;
        IAaveV4Spoke.UserAccountData memory a = IAaveV4Spoke(m.spoke).getUserAccountData(proxy);
        // A withdrawal refreshes the account to the reserve's latest collateral factor before Aave checks it.
        uint256 cf = _latestCf(m);
        uint256 left = _weightedLeft(m, a.totalCollateralValue, v.units, cf);
        v.healthFactorAfter = _hf(left, a.totalDebtValueRay);
        if (!own || v.units > limit) return v;
        if (a.totalDebtValueRay == 0) {
            v.allowed = true;
            return v;
        }
        v.allowed = _withdrawGate(m, marketId, proxy, left, cf, a.totalDebtValueRay);
    }

    /// @dev `⌊totalCollateralValue × CF / 10⁴⌋ − ⌈units × Pc × 10^(18 − d) × CF / 10⁴⌉`, floored at 0.
    function _weightedLeft(
        Market memory m,
        uint256 collateralValue,
        uint256 units,
        uint256 cf
    ) internal view returns (uint256) {
        uint256 w = collateralValue * cf / 1e4;
        uint256 removed = Math.mulDiv(units * _servedPrice(m) * 10 ** (18 - m.decimals), cf, 1e4, Math.Rounding.Ceil);
        return w - Math.min(w, removed);
    }

    /// @dev The withdraw-with-debt gate, with the rescue-excluded health factor at or above the floor.
    function _withdrawGate(
        Market memory m,
        uint256 marketId,
        address proxy,
        uint256 left,
        uint256 cf,
        uint256 debtRay
    ) internal view returns (bool) {
        AccountGateStatus memory st = IRiskModule(_RISK_MODULE).getAccountGateStatus(proxy);
        uint256 e = _rescueAt(m, proxy, cf);
        uint256 h0 = Math.max(_store().hardHealthFloor(marketId), WAD_);
        return st.withdrawWithDebtAllowed && st.pauseState != PauseState.Paused
            && _hf(left - Math.min(left, e), debtRay) >= h0;
    }
    // forge-lint: disable-end(calls-loop)

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
    function previewPledgeAfter(
        address wallet,
        uint256 marketId,
        bytes32 positionKey
    ) external view override returns (ActionPreview memory v) {
        _unlocked();
        Acct memory a;
        (a, v) = _start(wallet, marketId);
        v.amount = ILPVault(a.m.integration).validatePosition(marketId, wallet, positionKey);
        // A pledge that turns the collateral on refreshes the account's dynamic configuration (`setUsingAsCollateral`).
        uint256 cf = a.enabled ? _cf(a.m, a.proxy) : _latestCf(a.m);
        _finish(a, v, cf, a.held + v.amount, a.debtRay);
    }

    /// @inheritdoc ILensActions
    function previewWithdrawAfter(
        address wallet,
        uint256 marketId,
        bytes32 positionKey
    ) external view override returns (ActionPreview memory v) {
        _unlocked();
        Acct memory a;
        (a, v) = _start(wallet, marketId);
        ICollateralization coll = ICollateralization(_COLLATERALIZATION);
        uint256 id = coll.recordIdOf(a.m.integrationId, positionKey);
        if (id != 0 && coll.getRecord(id).proxy == a.proxy) {
            v.amount = coll.previewRelease(a.m.integrationId, positionKey);
        }
        uint256 cf = v.amount > 0 && a.enabled ? _latestCf(a.m) : _cf(a.m, a.proxy);
        _finish(a, v, cf, a.assets > v.amount ? a.assets - v.amount : 0, a.debtRay);
    }

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

    /// @dev The account's debt value (Aave value × RAY) after repaying `amount` of the reserve.
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

    /// @param core The nine core addresses, in `LensBase` order.
    constructor(
        address[9] memory core
    ) LensBase(core) {}
}
